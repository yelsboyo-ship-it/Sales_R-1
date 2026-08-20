# Sales Agent Stock Allocation - Implementation Summary

**Date Implemented**: 2026-07-25  
**Feature**: Automatic stock allocation to sales agents based on sales record shortfalls

---

## Overview

When a sales agent saves a sales record with `missing_in_kgs > 0`, the shortfall is automatically allocated to their `employee_stock_allocations.allocated_kg`. This is separate from and complementary to manager/supervisor-initiated manual transfers.

### Two Paths to Allocation

| Trigger | Path | Permission | Logged As | Example |
|---------|------|-----------|-----------|---------|
| Manager/Supervisor manual transfer | Transfer Stock modal → RPC `transfer_stock()` | Manager/Supervisor only | `warehouse_to_employee`, `employee_to_employee`, `employee_to_warehouse` | Manager allocates 50 kg to Agent |
| Sales agent saves record with shortfall | Automatic in `create_sales_record_with_inventory()` | None (automatic) | `sales_agent_allocation` | Agent saves record with 20 kg missing |

---

## Schema Changes

### 1. `stock_transfer_log` Table Extended

**Column Added**:
- `triggered_by_record_id` (bigint, FK to sales_records) — Points to sales record that triggered the allocation (null for manual transfers)

**Constraint Extended**:
- `transfer_type` check now includes: `'sales_agent_allocation'`

**Migration Line**: `stock_transfer_log` definition in `migration_stock_transfer.sql`

### 2. `employee_stock_allocations` Table (No Changes)

Still tracks `employee_id → produce_id → allocated_kg`  
Updates are now sourced from TWO places:
1. Manager/supervisor `transfer_stock()` RPC
2. Automatic shortfall allocation in `create_sales_record_with_inventory()`

---

## Implementation Details

### Location: `create_sales_record_with_inventory()` Function

**Where**: After produce stock deduction log, before return statement

**Logic**:
```sql
-- Only if produce_id is not null
if v_produce_id is not null then
  -- Get newly created record's missing_in_kgs
  select missing_in_kgs into v_missing_kg from public.sales_records where id = v_new_id
  
  -- If shortfall exists
  if missing_in_kgs > 0 then
    -- Allocate to current user (sales agent) - ADDITIVELY
    insert into employee_stock_allocations (employee_id, produce_id, allocated_kg)
    values (auth.uid(), v_produce_id, v_missing_kg)
    ON CONFLICT DO UPDATE
    set allocated_kg = allocated_kg + v_missing_kg
    
    -- Log to audit trail
    insert into stock_transfer_log (
      transfer_type = 'sales_agent_allocation',
      destination_employee_id = auth.uid(),
      triggered_by_record_id = v_new_id,
      remarks = 'Shortfall from sales record #<id>'
    )
  end if
end if
```

**Key Properties**:
- ✅ **Atomic**: Happens within same transaction as sales record creation
- ✅ **Additive**: Uses `ON CONFLICT DO UPDATE` to accumulate, not replace
- ✅ **Conditional**: Only if `v_produce_id` is not null AND `missing_in_kgs > 0`
- ✅ **Audited**: Every allocation logged with clear distinction
- ✅ **No Permission Check**: Sales agents can always do this (it's automatic)

---

## Behavior Examples

### Example 1: First Shortfall

Sales Agent saves:
- Produce: Tomatoes (id=5)
- Total: 50 kg, Supplied: 30 kg, Rejects: 0
- missing_in_kgs = 20 kg

**Result**:
- New row in `employee_stock_allocations`: `(user_123, 5, 20.00)`
- New row in `stock_transfer_log`:
  ```
  transfer_type: 'sales_agent_allocation'
  destination_employee_id: user_123
  produce_id: 5
  quantity_kg: 20.00
  triggered_by_record_id: sale_456
  performed_by: user_123
  remarks: 'Shortfall from sales record #456'
  ```

### Example 2: Second Shortfall (Same Agent, Same Produce)

Agent saves another record:
- Same produce (Tomatoes, id=5)
- missing_in_kgs = 15 kg

**Result**:
- Allocation INCREASES: 20.00 + 15.00 = 35.00 kg
- New log entry (separate record) with quantity_kg = 15.00
- Audit trail shows TWO allocations

### Example 3: Manager Transfer (Existing Flow)

Manager manually transfers:
- Source: Warehouse
- Destination: Same agent
- Produce: Tomatoes
- Quantity: 10 kg

**Result**:
- Allocation INCREASES: 35.00 + 10.00 = 45.00 kg
- New log entry with `transfer_type = 'warehouse_to_employee'`
- Different log entry than sales agent allocations
- `triggered_by_record_id = null` (no sales record triggered it)

---

## Distinguishing Log Entries

Query to see all ways an agent's allocation grew:

```sql
SELECT 
  id,
  transfer_type,
  quantity_kg,
  triggered_by_record_id,
  performed_by_email,
  remarks,
  created_at
FROM public.stock_transfer_log
WHERE destination_employee_id = '<agent_user_id>'
AND destination_type = 'employee'
ORDER BY created_at DESC;
```

**Result**:
- Rows with `transfer_type = 'sales_agent_allocation'` → Agent's own saves
- Rows with `transfer_type IN ('warehouse_to_employee', ...)` → Manager/supervisor transfers
- `triggered_by_record_id` populated only for sales agent allocations
- `performed_by_email` shows WHO initiated (agent vs manager)

---

## Row Shading (Unchanged)

Row shading in sales ledger UI is based on:
```
color = missing_in_kgs > 0 ? highlighted : normal
```

This logic is **completely independent** of allocations:
- Allocation doesn't clear the highlight
- Shortfall highlight exists regardless of whether stock was allocated to the agent
- Shading exists to indicate "this sale is incomplete" status
- Allocation exists to track "this agent has this much stock to sell"

These are two separate concerns:
- **Shading** = Sales status (incomplete vs complete)
- **Allocation** = Inventory assignment (who has what stock)

---

## Transaction Safety

The allocation insertion happens **within the same PL/pgSQL function** that creates the sales record:

```
BEGIN
  INSERT sales_record ← gets v_new_id
  UPDATE source record if needed
  INSERT produce_stock_log
  → [NEW CODE] INSERT employee_stock_allocations
  → [NEW CODE] INSERT stock_transfer_log
  RETURN sales record
END
```

If ANY step fails:
- ✅ **Entire transaction rolls back**
- ✅ **No partial allocations**
- ✅ **No orphaned log entries**
- ✅ **Atomicity guaranteed**

---

## Frontend (No Changes Needed)

Sales agents:
- See no new UI elements
- Save records normally
- Shortfalls are allocated automatically behind-the-scenes
- No permission errors or modal prompts

Row shading continues to work as before.

---

## Files Modified

1. **migration_stock_transfer.sql**
   - Line ~54: `stock_transfer_log` table definition
   - Added column: `triggered_by_record_id`
   - Extended constraint: `transfer_type` includes `'sales_agent_allocation'`

2. **supabase_schema.sql**
   - `create_sales_record_with_inventory()` function
   - Lines ~1568-1605: Added allocation logic block
   - Uses same transfer_log table and follows same pattern as `transfer_stock()` RPC

---

## No Changes To

✅ Row shading logic (UI)  
✅ Sales record creation form (frontend)  
✅ Manager/supervisor transfer feature (transfer_stock RPC)  
✅ Inactivity timeout  
✅ Edit history logging  
✅ Permission checks for sales agents  

---

## Testing Checklist

- [ ] Sales agent save with shortfall creates allocation
- [ ] Allocation is additive (multiple saves accumulate)
- [ ] No allocation when missing_in_kgs = 0
- [ ] Log entries have correct transfer_type and triggered_by_record_id
- [ ] Manager transfers still work unchanged
- [ ] Row shading NOT affected by allocations
- [ ] Transactions are atomic (no orphaned data)
- [ ] Different produce types create separate allocations
- [ ] Edge case: no produce_id (general records) don't cause errors

---

## Deployment Steps

1. Apply `migration_stock_transfer.sql` in Supabase SQL Editor
2. No frontend changes required
3. Test with sales agent creating records with shortfalls
4. Verify `stock_transfer_log` entries and `employee_stock_allocations` rows
5. Verify row shading still works
6. Run test cases from `SALES_AGENT_ALLOCATION_TEST_PLAN.md`

