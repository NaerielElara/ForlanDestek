import unittest
from unittest.mock import MagicMock, patch

from fastapi import HTTPException

from pydantic import ValidationError

from app.main import TicketInput, list_events, request_ticket_connection, require_admin, require_staff, visible_ticket


class _Result:
    def __init__(self, value):
        self.value = value

    def fetchone(self):
        return self.value


class _Connection:
    def __init__(self, ticket):
        self.ticket = ticket

    def execute(self, *_):
        return _Result(self.ticket)


class AuthorizationTests(unittest.TestCase):
    def test_ticket_category_is_limited_to_supported_categories(self):
        valid = TicketInput(category="Yazılım", title="Uygulama açılmıyor", description="Ayrıntı")
        self.assertEqual(valid.category, "Yazılım")
        with self.assertRaises(ValidationError):
            TicketInput(category="Diğer", title="Uygulama açılmıyor", description="Ayrıntı")

    def test_staff_and_admin_role_boundaries(self):
        self.assertEqual(require_staff({"role": "technician"})["role"], "technician")
        self.assertEqual(require_staff({"role": "admin"})["role"], "admin")
        with self.assertRaises(HTTPException) as customer_error:
            require_staff({"role": "customer"})
        self.assertEqual(customer_error.exception.status_code, 403)
        with self.assertRaises(HTTPException) as technician_error:
            require_admin({"role": "technician"})
        self.assertEqual(technician_error.exception.status_code, 403)

    def test_customer_can_only_access_their_own_ticket(self):
        ticket = {"id": 7, "customer_id": 11}
        self.assertEqual(
            visible_ticket(_Connection(ticket), 7, {"id": 11, "role": "customer", "license_id":1, "support_enabled":True}),
            ticket,
        )
        with self.assertRaises(HTTPException) as other_customer:
            visible_ticket(_Connection(ticket), 7, {"id": 12, "role": "customer", "license_id":1, "support_enabled":True})
        self.assertEqual(other_customer.exception.status_code, 404)
        self.assertEqual(
            visible_ticket(_Connection(ticket), 7, {"id": 12, "role": "technician"}),
            ticket,
        )

    def test_ticket_device_id_accepts_existing_clients_and_normalizes_digits(self):
        fields = {"category": "Sistem", "title": "Bağlantı sorunu", "description": "Ayrıntı"}
        self.assertIsNone(TicketInput(**fields).device_id)
        self.assertEqual(TicketInput(**fields, device_id="88 507 774").device_id, "88507774")
        with self.assertRaises(ValidationError):
            TicketInput(**fields, device_id="someone.example.com")

    def test_initial_event_poll_does_not_replay_history(self):
        pool = MagicMock()
        pool.connection.return_value.__enter__.return_value.execute.return_value.fetchone.return_value = {"cursor": 41}
        self.assertEqual(
            list_events(account={"id": 11, "role": "customer", "license_id":1, "support_enabled":True}, pool=pool),
            {"cursor": 41, "events": []},
        )

    def test_connection_request_requires_active_customer_license(self):
        pool = MagicMock()
        pool.connection.return_value.__enter__.return_value.execute.return_value.fetchone.return_value = {
            "id": 7, "customer_id": 11, "status": "open", "device_id": "88507774",
        }
        with patch("app.main.entitlements.ticket_has_support", return_value=False):
            with self.assertRaises(HTTPException) as rejected:
                request_ticket_connection(7, staff={"id": 12, "role": "technician"}, pool=pool)
        self.assertEqual(rejected.exception.status_code, 403)


if __name__ == "__main__":
    unittest.main()
