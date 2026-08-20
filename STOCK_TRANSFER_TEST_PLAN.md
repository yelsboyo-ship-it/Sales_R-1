# Stock Transfer Feature - Test Plan

## Test Environment Setup

1. **Database**: Migration applied to Supabase
2. **Frontend**: Changes applied to `sales-ledger.html`
3. **Users**: 
   - Manager account (role = 'manager')
   - Supervisor account (role = 'supervisor')
   - Accountant account (role = 'accountant')
   - Sales agent account (role = 'sales_agent' or other non-manager/supervisor)
4. **Data**: At least 2 employees, 3 produce types with warehouse stock

---

## Test Cases

### TC-001: UI Visibility (Role-Based)

**Precondition**: User logged in

| Role | Expected |
|------|----------|
| Manager | "Transfer Stock" button visible in header |
| Supervisor | "Transfer Stock" button visible in header |
| Accountant | "Transfer Stock" button NOT visible |
| Sales Agent | "Transfer Stock" button NOT visible |

**Steps**:
1. Log in as each role
2. Check header for "Transfer Stock" button presence
3. **Result**: ✅ if button visibility matches expected

---

### TC-002: Modal Opens & Populates

**Precondition**: Logged in as manager, warehouse has stock

**Steps**:
1. Click "Transfer Stock" button
2. Modal appears with:
   - Source: "Warehouse" selected by default
   - Destination: "Employee" selected by default
   - Produce dropdown populated with all available produce
   - Employee dropdowns populated
3. **Result**: ✅ if all fields populated correctly

---

### TC-003: Warehouse → Employee Transfer (Valid)

**Precondition**: 
- Logged in as manager
- Warehouse has 50 kg of "Tomatoes" available
- Employee "John Smith" selected

**Steps**:
1. Open Transfer Stock modal
2. Source: select "Warehouse"
3. Destination: select "Employee" → "John Smith"
4. Produce: select "Tomatoes"
5. Quantity: enter "20"
6. Remarks: enter "Initial allocation"
7. Click "Transfer Stock"

**Expected**:
- ✅ Success toast message
- ✅ Modal closes
- ✅ Warehouse stock decreases: 50 → 30 kg
- ✅ Employee allocation created/increased in `employee_stock_allocations`
- ✅ Entry logged in `stock_transfer_log` with `transfer_type = 'warehouse_to_employee'`

---

### TC-004: Employee → Employee Transfer (Valid)

**Precondition**:
- "John Smith" has 20 kg of "Tomatoes" allocated (from TC-003)
- "Jane Doe" is another employee
- Logged in as supervisor

**Steps**:
1. Open Transfer Stock modal
2. Source: select "Employee" → "John Smith"
3. Destination: select "Employee" → "Jane Doe"
4. Produce: select "Tomatoes"
5. Quantity: enter "15"
6. Remarks: enter "Shift handover"
7. Click "Transfer Stock"

**Expected**:
- ✅ Success message
- ✅ John Smith: 20 → 5 kg
- ✅ Jane Doe: 0 → 15 kg
- ✅ `transfer_type = 'employee_to_employee'` in log
- ✅ Both rows in `employee_stock_allocations` updated

---

### TC-005: Employee → Warehouse Transfer (Valid)

**Precondition**:
- "Jane Doe" has 15 kg of "Tomatoes" allocated (from TC-004)
- Warehouse has 30 kg
- Logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Source: select "Employee" → "Jane Doe"
3. Destination: select "Warehouse"
4. Produce: select "Tomatoes"
5. Quantity: enter "10"
6. Remarks: enter "Unsold return"
7. Click "Transfer Stock"

**Expected**:
- ✅ Success message
- ✅ Jane Doe: 15 → 5 kg
- ✅ Warehouse: 30 → 40 kg
- ✅ `transfer_type = 'employee_to_warehouse'` in log

---

### TC-006: Insufficient Stock Error

**Precondition**:
- "John Smith" has 5 kg of "Tomatoes" (from TC-004)
- Logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Source: "Employee" → "John Smith"
3. Destination: "Warehouse"
4. Produce: "Tomatoes"
5. Quantity: enter "10"
6. Click "Transfer Stock"

**Expected**:
- ❌ Error message: "STOCK_TRANSFER_INSUFFICIENT: employee has only 5 kg available"
- ❌ Modal stays open
- ❌ No database changes

---

### TC-007: Self-Transfer Rejection

**Precondition**: Logged in as supervisor

**Steps**:
1. Open Transfer Stock modal
2. Source: "Warehouse"
3. Destination: "Warehouse"
4. Quantity: any value
5. Click "Transfer Stock"

**Expected**:
- ❌ Error message: "source and destination cannot be the same"
- ❌ Modal stays open

**Alternative Case**:
- Source: "Employee" → "John Smith"
- Destination: "Employee" → "John Smith"
- **Result**: Same error

---

### TC-008: Permission Denied (Accountant via API)

**Precondition**: Logged in as accountant

**Steps**:
1. Try to open "Transfer Stock" (button should be hidden)
2. If button somehow appears, click it
3. Fill form and submit

**Expected**:
- ❌ Button not visible (passed TC-001)
- ❌ If form submitted via API directly:
  - Error: "STOCK_TRANSFER_FORBIDDEN: only managers and supervisors can transfer stock"
  - No database changes

---

### TC-009: Validation - Quantity = 0

**Precondition**: Logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Fill all fields
3. Quantity: enter "0" or leave blank
4. Click "Transfer Stock"

**Expected**:
- ❌ Error message: "Quantity must be greater than 0"
- ❌ Form stays open

---

### TC-010: Validation - No Produce Selected

**Precondition**: Logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Leave Produce dropdown as "Select produce..."
3. Fill other fields
4. Click "Transfer Stock"

**Expected**:
- ❌ Error message: "Please select a produce type"
- ❌ Form stays open

---

### TC-011: Validation - Employee Not Selected

**Precondition**: Logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Source: "Employee" (but don't select an employee)
3. Fill other fields
4. Click "Transfer Stock"

**Expected**:
- ❌ Error message: "Please select a source employee"
- ❌ Form stays open

---

### TC-012: Availability Hint Updates Dynamically

**Precondition**: Modal open, logged in as manager

**Steps**:
1. Open Transfer Stock modal
2. Source: "Warehouse"
3. Produce: select "Tomatoes" (warehouse currently has 40 kg)
4. Check "Available: 40 kg" hint displayed
5. Change to Source: "Employee" → "John Smith"
6. Produce: "Tomatoes"
7. Check hint updates to "Available: 5 kg"

**Expected**:
- ✅ Hint changes as source/produce selection changes
- ✅ Reflects current allocations correctly

---

### TC-013: Audit Trail Verification

**Precondition**: Multiple transfers completed (TC-003 through TC-005)

**Steps**:
1. Connect to Supabase dashboard
2. Query `stock_transfer_log` table
3. Verify entries:
   - `transfer_type` (warehouse_to_employee, employee_to_employee, employee_to_warehouse)
   - `performed_by` = current user ID
   - `performed_by_email` = current user email
   - `quantity_kg` matches submitted amount
   - `remarks` matches if provided
   - `created_at` is recent

**Expected**:
- ✅ All transfers logged
- ✅ All metadata correct
- ✅ No entries with null `performed_by`

---

### TC-014: Data Consistency After Transfer

**Precondition**: Multiple transfers completed, all statuses verified

**Steps**:
1. Manually verify in database:
   ```sql
   SELECT id, particulars, amount_kg FROM produce WHERE particulars = 'Tomatoes';
   SELECT id, allocated_kg FROM employee_stock_allocations 
   WHERE produce_id = <tomatoes_id> 
   ORDER BY employee_id;
   ```
2. Sum all employee allocations + warehouse qty
3. Compare to initial warehouse qty + any restocks

**Expected**:
- ✅ Total stock accounted for (no gain/loss due to transfers)
- ✅ No negative allocations
- ✅ Warehouse qty correct

---

### TC-015: Modal Closes and Data Persists

**Precondition**: Successful transfer completed

**Steps**:
1. After "Transfer Stock" modal closes
2. Reload page
3. Re-open Transfer Stock modal
4. Check dropdowns and form state

**Expected**:
- ✅ Modal form resets to defaults
- ✅ Dropdowns still show correct current values
- ✅ Previous transfer didn't corrupt data

---

## Regression Tests (Ensure No Breaking Changes)

### RG-001: Sales Records Still Create Normally
- New sale entry creates correctly
- Dispatch quantity auto-filled from N+1 logic
- Bank account recording still works (with fix)

### RG-002: Produce Restock Still Works
- Warehouse qty increases via restock
- Restock log created normally

### RG-003: Inactivity Timeout Not Affected
- User can be inactive for >2 minutes in normal operations
- Stock Transfer modal respects timeout

### RG-004: Other RPC Functions Still Work
- `create_sales_record_with_inventory` (14-param version)
- Any other existing RPC functions

---

## Pass/Fail Summary

**All tests pass**: Feature ready for production
**Any failure in TC-001 to TC-015**: Investigate before deployment
**Regression tests**: Should pass to avoid side effects

