# Stock Transfer Feature - Implementation Summary

## Completed Artifacts

### 1. **Database Migration** ([migration_stock_transfer.sql](migration_stock_transfer.sql))
   - **Tables Created**:
     - `public.employee_stock_allocations` — Tracks allocated stock per employee/produce
     - `public.stock_transfer_log` — Audit trail of all transfers
   - **RPC Function**: `public.transfer_stock()` with full validation
   - **RLS Policies**: Manager/supervisor only access
   - **Atomicity**: All updates within single transaction

### 2. **Frontend Implementation** ([FRONTEND_DIFF_STOCK_TRANSFER.md](FRONTEND_DIFF_STOCK_TRANSFER.md))
   - **Button**: "Transfer Stock" added to header (manager/supervisor only)
   - **Modal**: Two-column form with source/destination selectors
   - **Validation**: Client-side quantity & self-transfer checks
   - **Error Handling**: Specific messages for permission denied, insufficient stock, invalid config
   - **Auto-refresh**: Reloads produce catalog after successful transfer

### 3. **Bank Name Recording Fix**
   - ✅ Accounting form now extracts selected bank account label from dropdown
   - ✅ Sends correct `p_bank_account` parameter to RPC

---

## Schema Details

### `employee_stock_allocations` Table
```sql
id              bigint PK
employee_id     uuid (FK → auth.users)
produce_id      bigint (FK → produce)
allocated_kg    numeric(10,2)
created_at      timestamptz
updated_at      timestamptz
UNIQUE(employee_id, produce_id)
```

### `stock_transfer_log` Table
```sql
id                      bigint PK
transfer_type           text CHECK (warehouse_to_employee | employee_to_employee | employee_to_warehouse)
source_type             text
source_employee_id      uuid (null if warehouse)
destination_type        text
destination_employee_id uuid (null if warehouse)
produce_id              bigint FK
quantity_kg             numeric(10,2)
performed_by            uuid FK
performed_by_email      text
remarks                 text
created_at              timestamptz
```

### RPC Function Signature
```sql
transfer_stock(
  p_source_type text,
  p_source_employee_id uuid,
  p_destination_type text,
  p_destination_employee_id uuid,
  p_produce_id bigint,
  p_quantity_kg numeric,
  p_performed_by uuid,
  p_remarks text
) → json
```

---

## Server-Side Validation (All 3 Types)

✅ **Role Check**: Only manager/supervisor can call (via `raw_user_meta_data ->> 'role'`)
✅ **Source ≠ Destination**: Prevent self-transfers
✅ **Quantity > 0**: Reject zero or negative
✅ **Sufficient Stock**: Check source has enough qty before transfer
✅ **Atomic Transfer**: Both source decrement & destination increment in single transaction
✅ **Audit Log**: Every transfer recorded with performer, timestamp, remarks

---

## Supported Transfer Types

| Type | Source | Destination | Use Case |
|------|--------|-------------|----------|
| **warehouse → employee** | Central pool | Agent | Allocate stock to sales agent |
| **employee → employee** | Agent A | Agent B | Reassign unfinished stock |
| **employee → warehouse** | Agent | Central pool | Return unused stock |

---

## Frontend Features

- **Role-gated UI**: Button visible only to manager/supervisor
- **Source/Destination Toggle**: Radio buttons switch between "Warehouse" ↔ "Employee"
- **Employee Dropdowns**: Auto-populate from `employees` table
- **Produce Dropdown**: Shows all available produce with current warehouse qty
- **Availability Hint**: Displays source qty dynamically as user selects produce
- **Error Messages**: Specific, actionable error text for all failure scenarios
- **Atomic Feedback**: Single success message after transfer completes

---

## Pre-Implementation Checklist

- [ ] Run migration in Supabase SQL Editor: `migration_stock_transfer.sql`
- [ ] Apply frontend changes from `FRONTEND_DIFF_STOCK_TRANSFER.md` to `sales-ledger.html`
- [ ] Test: Manager can open "Transfer Stock" modal; accountant cannot
- [ ] Test: Warehouse → Employee transfer (new employee allocation created)
- [ ] Test: Employee → Employee transfer (balance transferred atomically)
- [ ] Test: Employee → Warehouse transfer (allocation decremented, warehouse incremented)
- [ ] Test: Insufficient stock rejection
- [ ] Test: Self-transfer rejection
- [ ] Verify audit log entries in `stock_transfer_log`

---

## Notes

- **Employee Stock Allocations**: Initially empty; first warehouse→employee transfer creates the row
- **Warehouse Stock**: Decremented directly from `produce.amount_kg`
- **Conflict Resolution**: Uses `ON CONFLICT DO UPDATE` for upsert on employee allocations
- **Role Enforcement**: Server-side check is mandatory; frontend check is UX only
- **No Impact on Sales Records**: Stock transfers are independent from sales ledger logic

