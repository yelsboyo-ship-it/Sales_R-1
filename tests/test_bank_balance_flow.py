from __future__ import annotations

import copy
import pathlib
import re
import unittest
from dataclasses import dataclass


@dataclass
class LedgerState:
    bank_current_balance: float = 0.0
    cash_book_balance: float = 0.0
    adjustment_new_balance: float = 0.0


class BankPostingService:
    """In-memory model of the invariant chain used by SQL posting logic."""

    def __init__(self, opening_balance: float = 0.0):
        self.state = LedgerState(
            bank_current_balance=opening_balance,
            cash_book_balance=opening_balance,
            adjustment_new_balance=opening_balance,
        )

    def post_to_bank_account(
        self,
        amount_delta: float,
        *,
        fail_after_bank_update: bool = False,
        fail_after_cash_book_sync: bool = False,
    ) -> float:
        # Transaction simulation: update staged copy first, then commit atomically.
        staged = copy.deepcopy(self.state)
        staged.bank_current_balance += amount_delta
        if fail_after_bank_update:
            raise RuntimeError("forced failure after bank update")

        staged.cash_book_balance = staged.bank_current_balance
        if fail_after_cash_book_sync:
            raise RuntimeError("forced failure after cash book sync")

        staged.adjustment_new_balance = staged.bank_current_balance

        self.state = staged
        return self.state.bank_current_balance

    def approve_sale(self, deposited_amount: float, **kwargs) -> float:
        return self.post_to_bank_account(deposited_amount, **kwargs)

    def apply_expense(self, amount: float, **kwargs) -> float:
        return self.post_to_bank_account(-abs(amount), **kwargs)

    def apply_purchase(self, amount: float, **kwargs) -> float:
        return self.post_to_bank_account(-abs(amount), **kwargs)


class BankBalanceRegressionTests(unittest.TestCase):
    def test_single_approval_increments_balance_once(self):
        svc = BankPostingService(opening_balance=1000.0)

        svc.approve_sale(250.0)

        self.assertEqual(svc.state.bank_current_balance, 1250.0)

    def test_post_approval_mirrors_cash_book_and_adjustments(self):
        svc = BankPostingService(opening_balance=1000.0)

        svc.approve_sale(300.0)

        self.assertEqual(svc.state.cash_book_balance, svc.state.bank_current_balance)
        self.assertEqual(svc.state.adjustment_new_balance, svc.state.bank_current_balance)

    def test_multiple_approvals_accumulate_without_drift(self):
        svc = BankPostingService(opening_balance=0.0)

        svc.approve_sale(100.0)
        svc.approve_sale(200.0)
        svc.approve_sale(50.0)

        self.assertEqual(svc.state.bank_current_balance, 350.0)
        self.assertEqual(svc.state.cash_book_balance, 350.0)
        self.assertEqual(svc.state.adjustment_new_balance, 350.0)

    def test_expense_and_purchase_decrement_and_stay_synced(self):
        svc = BankPostingService(opening_balance=1000.0)

        svc.apply_expense(120.0)
        svc.apply_purchase(80.0)

        self.assertEqual(svc.state.bank_current_balance, 800.0)
        self.assertEqual(svc.state.cash_book_balance, 800.0)
        self.assertEqual(svc.state.adjustment_new_balance, 800.0)

    def test_transaction_rolls_back_on_chain_failure(self):
        svc = BankPostingService(opening_balance=1000.0)

        with self.assertRaises(RuntimeError):
            svc.approve_sale(500.0, fail_after_bank_update=True)
        self.assertEqual(svc.state.bank_current_balance, 1000.0)
        self.assertEqual(svc.state.cash_book_balance, 1000.0)
        self.assertEqual(svc.state.adjustment_new_balance, 1000.0)

        with self.assertRaises(RuntimeError):
            svc.approve_sale(500.0, fail_after_cash_book_sync=True)
        self.assertEqual(svc.state.bank_current_balance, 1000.0)
        self.assertEqual(svc.state.cash_book_balance, 1000.0)
        self.assertEqual(svc.state.adjustment_new_balance, 1000.0)


class SqlGuardRegressionTests(unittest.TestCase):
    def test_approve_sales_record_uses_single_post_function(self):
        schema_path = pathlib.Path(__file__).resolve().parents[1] / "supabase_schema.sql"
        sql = schema_path.read_text(encoding="utf-8")

        approve_block = re.search(
            r"create or replace function public\.approve_sales_record\(.*?\$\$;",
            sql,
            flags=re.IGNORECASE | re.DOTALL,
        )
        self.assertIsNotNone(approve_block)
        block_text = approve_block.group(0)

        self.assertIn("perform public.post_to_bank_account(", block_text)
        self.assertNotRegex(block_text, r"update\s+public\.bank_accounts\s+set\s+current_balance")

    def test_approve_sales_record_uses_sale_linked_debtor_creditor_guardrails(self):
        schema_path = pathlib.Path(__file__).resolve().parents[1] / "supabase_schema.sql"
        sql = schema_path.read_text(encoding="utf-8")

        self.assertIn("alter table public.accounting_debtors", sql)
        self.assertIn("alter table public.accounting_creditors", sql)
        self.assertIn("sales_record_id bigint references public.sales_records(id) on delete set null", sql)
        self.assertIn("create unique index if not exists idx_accounting_debtors_sales_record_unique", sql)
        self.assertIn("create unique index if not exists idx_accounting_creditors_sales_record_unique", sql)
        self.assertIn("create or replace function public.upsert_sales_record_accounting_obligation", sql)
        self.assertIn("perform public.upsert_sales_record_accounting_obligation(p_sale_id)", sql)

    def test_direct_balance_write_guard_exists(self):
        schema_path = pathlib.Path(__file__).resolve().parents[1] / "supabase_schema.sql"
        sql = schema_path.read_text(encoding="utf-8")

        self.assertIn("create or replace function public.prevent_direct_bank_balance_update()", sql)
        self.assertIn("Direct updates to bank_accounts.current_balance are not allowed", sql)


if __name__ == "__main__":
    unittest.main()
