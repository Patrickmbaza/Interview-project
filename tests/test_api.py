from app.main import health, message, root



def test_health():
    assert health()["status"] == "healthy"


def test_root_contains_service_information():
    assert "name" in root()


def test_message():
    assert message()["message"]
