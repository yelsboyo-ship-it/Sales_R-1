from __future__ import annotations

VALID_DELIVERY_STATUSES = {
    'pending',
    'assigned',
    'in_transit',
    'delivered',
    'cancelled',
    'not_applicable',
}

VALID_TRANSITIONS = {
    'pending': {'assigned', 'cancelled', 'not_applicable'},
    'assigned': {'in_transit', 'cancelled'},
    'in_transit': {'delivered', 'cancelled'},
    'delivered': set(),
    'cancelled': set(),
    'not_applicable': set(),
}


def normalize_delivery_status(value: str | None, default: str = 'pending') -> str:
    if value is None:
        return default
    normalized = str(value).strip().lower().replace(' ', '_').replace('-', '_')
    normalized = normalized.replace('__', '_')
    aliases = {
        'in_transit': 'in_transit',
        'intransit': 'in_transit',
        'in transit': 'in_transit',
        'assigned': 'assigned',
        'delivered': 'delivered',
        'cancelled': 'cancelled',
        'canceled': 'cancelled',
        'not_applicable': 'not_applicable',
        'na': 'not_applicable',
        'pending': 'pending',
    }
    if normalized in aliases:
        return aliases[normalized]
    return default if normalized not in VALID_DELIVERY_STATUSES else normalized


def get_delivery_status_for_payment_option(payment_option: str | None, delivery_status: str | None) -> str:
    normalized_payment_option = str(payment_option or '').strip().lower()
    if normalized_payment_option == 'pay_now':
        return 'not_applicable'
    return normalize_delivery_status(delivery_status, default='pending')


def can_transition_delivery_status(current_status: str | None, next_status: str | None) -> bool:
    current = normalize_delivery_status(current_status, default='pending')
    next_value = normalize_delivery_status(next_status, default='pending')
    if current == 'not_applicable' or next_value == 'not_applicable':
        return False
    return next_value in VALID_TRANSITIONS.get(current, set())


def apply_delivery_transition(payment_option: str | None, current_status: str | None, next_status: str | None) -> str:
    if str(payment_option or '').strip().lower() == 'pay_now':
        return 'not_applicable'
    normalized_current = normalize_delivery_status(current_status, default='pending')
    normalized_next = normalize_delivery_status(next_status, default='pending')
    if normalized_next == 'pending':
        return normalized_current
    if can_transition_delivery_status(normalized_current, normalized_next):
        return normalized_next
    return normalized_current
