from __future__ import annotations

import unittest
from dataclasses import dataclass


@dataclass
class Record:
    record_id: int
    particulars: str
    total_dispatch_kg: float
    kgs_supplied: float
    rejects_kg: float
    missing_in_kgs: float


@dataclass
class EditHistoryEntry:
    record_id: int
    field_changed: str
    old_value: float
    new_value: float
    note: str


class CarryForwardRegressionTests(unittest.TestCase):
    def run_carry_forward_sequence(self):
        records: list[Record] = []
        history: list[EditHistoryEntry] = []
        snapshots: list[tuple[tuple[float, float, float], tuple[float, float, float], tuple[float, float, float], tuple[float, float, float]]] = []

        def latest_prior(particulars: str) -> Record | None:
            return max(
                (r for r in records if r.particulars == particulars),
                key=lambda r: r.record_id,
                default=None,
            )

        def save_record(record: Record):
            prior = latest_prior(record.particulars)
            carried_missing = float(prior.missing_in_kgs) if prior and prior.missing_in_kgs > 0 else 0.0

            if prior and prior.missing_in_kgs > 0:
                old_dispatch = prior.total_dispatch_kg
                old_missing = prior.missing_in_kgs
                new_dispatch = prior.kgs_supplied + prior.rejects_kg
                prior.total_dispatch_kg = new_dispatch
                prior.missing_in_kgs = 0
                history.append(
                    EditHistoryEntry(
                        record_id=prior.record_id,
                        field_changed='total_dispatch_kg',
                        old_value=old_dispatch,
                        new_value=new_dispatch,
                        note=f"closed out on save of record_id {record.record_id}",
                    )
                )
                history.append(
                    EditHistoryEntry(
                        record_id=prior.record_id,
                        field_changed='missing_in_kgs',
                        old_value=old_missing,
                        new_value=0,
                        note=f"consumed by record_id {record.record_id}",
                    )
                )

            if carried_missing > 0:
                record.total_dispatch_kg = carried_missing

            records.append(record)
            record.missing_in_kgs = record.total_dispatch_kg - (record.kgs_supplied + record.rejects_kg)

            snapshots.append(
                (
                    (records[0].total_dispatch_kg, records[0].kgs_supplied, records[0].missing_in_kgs),
                    (records[1].total_dispatch_kg, records[1].kgs_supplied, records[1].missing_in_kgs) if len(records) > 1 else (0.0, 0.0, 0.0),
                    (records[2].total_dispatch_kg, records[2].kgs_supplied, records[2].missing_in_kgs) if len(records) > 2 else (0.0, 0.0, 0.0),
                    (records[3].total_dispatch_kg, records[3].kgs_supplied, records[3].missing_in_kgs) if len(records) > 3 else (0.0, 0.0, 0.0),
                )
            )

        save_record(Record(record_id=1, particulars='apples', total_dispatch_kg=1000, kgs_supplied=75, rejects_kg=0, missing_in_kgs=925))
        save_record(Record(record_id=2, particulars='apples', total_dispatch_kg=925, kgs_supplied=25, rejects_kg=0, missing_in_kgs=0))
        save_record(Record(record_id=3, particulars='apples', total_dispatch_kg=900, kgs_supplied=35, rejects_kg=0, missing_in_kgs=0))
        save_record(Record(record_id=4, particulars='apples', total_dispatch_kg=865, kgs_supplied=400, rejects_kg=0, missing_in_kgs=0))

        return records, history, snapshots

    def test_carry_forward_closes_previous_record_without_touching_supplied_kg(self):
        records, history, snapshots = self.run_carry_forward_sequence()

        record_1 = next(r for r in records if r.record_id == 1)
        record_2 = next(r for r in records if r.record_id == 2)
        record_3 = next(r for r in records if r.record_id == 3)
        record_4 = next(r for r in records if r.record_id == 4)

        self.assertEqual(snapshots[0][0], (1000, 75, 925))
        self.assertEqual(snapshots[1][0], (75, 75, 0))
        self.assertEqual(snapshots[1][1], (925, 25, 900))
        self.assertEqual(snapshots[2][0], (75, 75, 0))
        self.assertEqual(snapshots[2][1], (25, 25, 0))
        self.assertEqual(snapshots[2][2], (900, 35, 865))
        self.assertEqual(snapshots[3][0], (75, 75, 0))
        self.assertEqual(snapshots[3][1], (25, 25, 0))
        self.assertEqual(snapshots[3][2], (35, 35, 0))
        self.assertEqual(snapshots[3][3], (865, 400, 465))

        self.assertEqual((record_1.total_dispatch_kg, record_1.kgs_supplied, record_1.missing_in_kgs), (75, 75, 0))
        self.assertEqual((record_2.total_dispatch_kg, record_2.kgs_supplied, record_2.missing_in_kgs), (25, 25, 0))
        self.assertEqual((record_3.total_dispatch_kg, record_3.kgs_supplied, record_3.missing_in_kgs), (35, 35, 0))
        self.assertEqual((record_4.total_dispatch_kg, record_4.kgs_supplied, record_4.missing_in_kgs), (865, 400, 465))

        self.assertEqual(
            [entry.field_changed for entry in history],
            ['total_dispatch_kg', 'missing_in_kgs', 'total_dispatch_kg', 'missing_in_kgs', 'total_dispatch_kg', 'missing_in_kgs'],
        )
        self.assertEqual([entry.old_value for entry in history[::2]], [1000, 925, 900])
        self.assertEqual([entry.new_value for entry in history[::2]], [75, 25, 35])
        self.assertEqual([entry.old_value for entry in history[1::2]], [925, 900, 865])
        self.assertEqual([entry.new_value for entry in history[1::2]], [0, 0, 0])
        self.assertTrue(all(entry.note.startswith('closed out on save of record_id') or entry.note.startswith('consumed by record_id') for entry in history))

        self.assertEqual(record_1.kgs_supplied, 75)
        self.assertEqual(record_2.kgs_supplied, 25)
        self.assertEqual(record_3.kgs_supplied, 35)


if __name__ == '__main__':
    unittest.main()
