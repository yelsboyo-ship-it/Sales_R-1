# Sales Agent Stock Allocation - Test Plan

## Feature Context

When a sales agent saves a sales record with `missing_in_kgs > 0`, that shortfall is automatically allocated to their `employee_stock_allocations.allocated_kg`. This accumulates additively on top of existing allocations.

**Distinguishing Features:**
- `transfer_type = 'sales_agent_allocation'` in stock_transfer_log
- `triggered_by_record_id` = the sales record that generated the shortfall
- No manager/supervisor permission required (unlike manual transfers)
- Does NOT affect row shading (which is based directly on missing_in_kgs)

---

## Test Cases

### TC-SA-001: Sales Agent Save with missing_in_kgs > 0

**Precondition:**
- Sales agent logged in
- Produce "Tomatoes" exists with 100 kg warehouse stock
- No prior allocation for this agent on Tomatoes

**Steps:**
1. Create new sales record:
   - Produce: "Tomatoes"
   - Total dispatch: 50 kg
   - Kgs supplied: 30 kg
   - Rejects: 0 kg
   - Unit price: 100
   - Amount deposited: 3000
2. Click Save
3. Check `employee_stock_allocations` table
4. Check `stock_transfer_log` table
5. Check UI doesn't show any modal/permission error

**Expected:**
- ✅ Sales record created successfully
- ✅ missing_in_kgs = 50 - 30 = 20 kg
- ✅ Employee allocation created: `allocated_kg = 20`
- ✅ Log entry created:
  - `transfer_type = 'sales_agent_allocation'`
  - `destination_employee_id = <agent's user id>`
  - `quantity_kg = 20`
  - `triggered_by_record_id = <sales record id>`
  - `performed_by = <agent's user id>`
  - `remarks = 'Shortfall from sales record #<id>'`
- ✅ No permission error (agent can do this)
- ✅ Warehouse stock unaffected (still 100 kg)

---

### TC-SA-002: Sales Agent Save with missing_in_kgs = 0 (No Allocation)

**Precondition:**
- Sales agent logged in
- Produce "Tomatoes" exists

**Steps:**
1. Create sales record with:
   - Total dispatch: 50 kg
   - Kgs supplied: 50 kg
   - Rejects: 0 kg
2. Save

**Expected:**
- ✅ Sales record created
- ✅ missing_in_kgs = 0
- ❌ NO entry in `employee_stock_allocations`
- ❌ NO entry in `stock_transfer_log` (for this record)
- ✅ Record shows no shortfall

---

### TC-SA-003: Multiple Saves — Additive Allocation

**Precondition:**
- From TC-SA-001, agent has 20 kg Tomatoes allocated
- Produce still has stock

**Steps:**
1. Create second sales record (same agent, same produce):
   - Total: 60 kg
   - Supplied: 40 kg
   - Rejects: 0 kg
   - missing_in_kgs = 20 kg
2. Save

**Expected:**
- ✅ Agent's allocation INCREASES: 20 + 20 = 40 kg
- ✅ New log entry created (separate record)
- ✅ Both log entries present in stock_transfer_log

**Verify in DB:**
```sql
SELECT allocated_kg FROM employee_stock_allocations 
WHERE employee_id = '<agent_id>' AND produce_id = <tomatoes_id>;
-- Should return: 40

SELECT COUNT(*) FROM stock_transfer_log 
WHERE transfer_type = 'sales_agent_allocation' 
AND destination_employee_id = '<agent_id>';
-- Should return: 2 (one for each save)
```

---

### TC-SA-004: Different Produce Types — Separate Allocations

**Precondition:**
- Agent has 20 kg Tomatoes allocated
- Produce "Peppers" also exists

**Steps:**
1. Create sales record for Peppers:
   - Total: 30 kg
   - Supplied: 20 kg
   - missing_in_kgs = 10 kg
2. Save

**Expected:**
- ✅ Agent now has:
  - 20 kg Tomatoes
  - 10 kg Peppers
- ✅ Two separate rows in employee_stock_allocations
- ✅ Two separate log entries for different produce

---

### TC-SA-005: Manager Transfer Still Works (Unchanged)

**Precondition:**
- Manager logged in
- Agent has 20 kg Tomatoes from sales

**Steps:**
1. Open "Transfer Stock" modal
2. Source: Warehouse
3. Destination: Employee (same agent)
4. Produce: Tomatoes
5. Quantity: 15 kg
6. Remarks: "Manager allocation"
7. Submit

**Expected:**
- ✅ Transfer succeeds
- ✅ Agent allocation: 20 + 15 = 35 kg
- ✅ Log entry with `transfer_type = 'warehouse_to_employee'`
- ✅ Different log entry than sales_agent_allocation
- ✅ source_type/destination_type fields populated
- ✅ NO triggered_by_record_id (null for manager transfers)

---

### TC-SA-006: Row Shading NOT Affected

**Precondition:**
- Row shading is based on missing_in_kgs > 0 (independent logic)

**Steps:**
1. Create sales with missing_in_kgs = 20
2. Save (allocation created)
3. Check row color in sales ledger UI
4. Create manager transfer of same 20 kg to agent
5. Check row color again

**Expected:**
- ✅ Row is shaded when missing_in_kgs > 0 (regardless of allocation)
- ✅ Row stays shaded (allocation doesn't clear the shortfall indicator)
- ✅ Color logic unchanged

---

### TC-SA-007: Accountant Cannot Perform Allocation (Role Check)

**Precondition:**
- Accountant logged in
- No "Transfer Stock" button visible

**Steps:**
1. Try to save a sales record with missing_in_kgs > 0
   (From accountant's perspective, this is just a normal save)

**Expected:**
- ✅ Sales record saves normally
- ✅ Allocation is still created (it's automatic, not accountant-initiated)
- ⚠️ Note: The server-side role check only applies to MANUAL transfers,
  not to automatic allocations triggered by sales saves

---

### TC-SA-008: Audit Trail Distinguishes Events

**Precondition:**
- Agent saved record with shortfall (TC-SA-001)
- Manager transferred stock to same agent (TC-SA-005)

**Steps:**
1. Query stock_transfer_log for this agent
2. Examine all entries

**Expected:**
- ✅ Entry 1: `transfer_type = 'sales_agent_allocation'`, `triggered_by_record_id = <record_id>`, `performed_by = <agent>`
- ✅ Entry 2: `transfer_type = 'warehouse_to_employee'`, `triggered_by_record_id = null`, `performed_by = <manager>`
- ✅ Clear distinction between who initiated and what triggered

---

### TC-SA-009: Null Produce ID (Edge Case)

**Precondition:**
- Create sales record WITH particulars text but NO matching produce

**Steps:**
1. Try to save (should fail with "Produce not available" error)

**Expected:**
- ❌ Save fails with error
- ❌ No allocation created
- ❌ No log entry created

**Precondition 2:**
- Create sales record WITHOUT particulars (general record)
- Total: 50, Supplied: 30, missing_in_kgs = 20

**Steps:**
1. Save

**Expected:**
- ✅ Sales record created
- ❌ NO allocation created (v_produce_id is null)
- ❌ NO log entry created
- Note: This is correct because we don't know which produce the shortfall is for

---

### TC-SA-010: Atomicity — All or Nothing

**Precondition:**
- Create scenario where RLS might block the allocation insert

**Steps:**
1. Save sales record that would trigger allocation
2. Monitor transaction

**Expected:**
- ✅ If RLS blocks employee_stock_allocations insert, entire transaction rolls back
- ✅ Sales record NOT created
- ✅ Produce stock NOT deducted
- ✅ No partial state

---

## Regression Tests

### RG-SA-001: Existing Sales Create Workflow Still Works
- New sales records can still be created without any changes
- Dispatch qty calculation unchanged
- Bank account recording (recent fix) still works
- No new required fields

### RG-SA-002: Accounting Module Unaffected
- Accountant can still view/edit sales records
- Accounting entries still save
- Permission checks unchanged

### RG-SA-003: Inactivity Timeout Unaffected
- User can be inactive for 2+ minutes without issue
- Stock allocation doesn't interfere with timeout

### RG-SA-004: Edit History Still Logged
- When saving a sales record, edit_history entries still created
- New allocation doesn't replace or interfere with edit_history

---

## SQL Validation Queries

```sql
-- Verify allocation was created
SELECT e.id, e.employee_id, e.produce_id, e.allocated_kg, e.created_at
FROM public.employee_stock_allocations e
WHERE e.employee_id = '<agent_user_id>'
ORDER BY e.created_at DESC;

-- Verify log entries distinguish transfer types
SELECT id, transfer_type, performed_by_email, quantity_kg, triggered_by_record_id, created_at
FROM public.stock_transfer_log
WHERE destination_employee_id = '<agent_user_id>'
ORDER BY created_at DESC;

-- Verify transfer_type constraint includes new type
SELECT constraint_name, check_clause
FROM information_schema.check_constraints
WHERE table_name = 'stock_transfer_log' AND constraint_name LIKE '%transfer_type%';
-- Should show: 'warehouse_to_employee', 'employee_to_employee', 'employee_to_warehouse', 'sales_agent_allocation'

-- Verify atomicity (no orphaned allocations)
SELECT COUNT(*) as orphaned_allocations
FROM public.employee_stock_allocations e
WHERE NOT EXISTS (
  SELECT 1 FROM auth.users u WHERE u.id = e.employee_id
);
-- Should return: 0
```

---

## Pass/Fail Criteria

**All tests pass**: Feature ready for production
**TC-SA-001 fails**: Core functionality broken, do not deploy
**TC-SA-005 fails**: Manager transfers broken, do not deploy
**RG-SA-001 or RG-SA-002 fails**: Regression detected, do not deploy

---

## Notes

- **No Permission Check Required**: Sales agents can save records with shortfalls automatically
- **Additive Only**: Allocations never decrease from sales saves (only increase or stay same)
- **Row Shading Independent**: Color shading is still based directly on missing_in_kgs, not on allocations
- **Audit Trail Complete**: Every add-to-allocation is logged regardless of source

