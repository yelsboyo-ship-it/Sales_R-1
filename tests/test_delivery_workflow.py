from __future__ import annotations

import unittest

from delivery_workflow import (
    apply_delivery_transition,
    can_transition_delivery_status,
    get_delivery_status_for_payment_option,
    normalize_delivery_status,
)


class DeliveryWorkflowTests(unittest.TestCase):
    def test_pay_on_delivery_defaults_to_pending(self):
        self.assertEqual(get_delivery_status_for_payment_option('payment_on_delivery', None), 'pending')
        self.assertEqual(get_delivery_status_for_payment_option('payment_on_delivery', ''), 'pending')
        self.assertEqual(get_delivery_status_for_payment_option('pay_now', None), 'not_applicable')

    def test_normalization_accepts_common_variants(self):
        self.assertEqual(normalize_delivery_status(' ASSIGNED '), 'assigned')
        self.assertEqual(normalize_delivery_status('In_Transit'), 'in_transit')
        self.assertEqual(normalize_delivery_status('unknown', default='pending'), 'pending')

    def test_delivery_transitions_follow_a_single_path(self):
        self.assertTrue(can_transition_delivery_status('pending', 'assigned'))
        self.assertTrue(can_transition_delivery_status('assigned', 'in_transit'))
        self.assertTrue(can_transition_delivery_status('in_transit', 'delivered'))
        self.assertFalse(can_transition_delivery_status('pending', 'delivered'))
        self.assertFalse(can_transition_delivery_status('delivered', 'assigned'))

    def test_apply_transition_returns_normalized_status(self):
        self.assertEqual(apply_delivery_transition('payment_on_delivery', 'pending', 'ASSIGNED'), 'assigned')
        self.assertEqual(apply_delivery_transition('pay_now', 'pending', 'delivered'), 'not_applicable')


if __name__ == '__main__':
    unittest.main()
