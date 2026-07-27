import os
import sys
import types
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1]
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

os.environ.setdefault("PROJECT_ID", "unit-test-project")
os.environ.setdefault("INPUT_SUBSCRIPTION", "unit-test-subscription")
os.environ.setdefault("OUTPUT_TOPIC", "unit-test-topic")
os.environ.setdefault("POLICY_FILE", str(PYTHON_DIR.parent / "policy" / "governance" / "remediation.rego"))
os.environ.setdefault(
    "KMS_KEY_VERSION",
    "projects/unit-test-project/locations/us-central1/keyRings/test/cryptoKeys/approval/cryptoKeyVersions/1",
)

# Unit tests must never touch real GCP services. Agent modules construct
# Pub/Sub, Firestore, and KMS clients at import time, and those real clients
# perform Application Default Credentials discovery in their constructor —
# which fails wherever ADC isn't configured (e.g. CI). Install lightweight
# stand-ins for these submodules unconditionally, before any test imports an
# agent module, regardless of whether the real google-cloud packages are
# installed (they are, since those packages are also production
# dependencies).
google = sys.modules.setdefault("google", types.ModuleType("google"))
cloud = sys.modules.setdefault("google.cloud", types.ModuleType("google.cloud"))
google.cloud = cloud


class _Future:
    def result(self, timeout=None):
        return "unit-test-message-id"


class _PublisherClient:
    def topic_path(self, project, topic):
        return f"projects/{project}/topics/{topic}"
    def publish(self, *args, **kwargs):
        return _Future()


class _SubscriberClient:
    def subscription_path(self, project, subscription):
        return f"projects/{project}/subscriptions/{subscription}"


class _FlowControl:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


pubsub_v1 = types.ModuleType("google.cloud.pubsub_v1")
pubsub_v1.PublisherClient = _PublisherClient
pubsub_v1.SubscriberClient = _SubscriberClient
pubsub_v1.types = types.SimpleNamespace(FlowControl=_FlowControl)
cloud.pubsub_v1 = pubsub_v1
sys.modules["google.cloud.pubsub_v1"] = pubsub_v1

subscriber = types.ModuleType("google.cloud.pubsub_v1.subscriber")
message_module = types.ModuleType("google.cloud.pubsub_v1.subscriber.message")
message_module.Message = object
subscriber.message = message_module
sys.modules["google.cloud.pubsub_v1.subscriber"] = subscriber
sys.modules["google.cloud.pubsub_v1.subscriber.message"] = message_module


class _Document:
    def get(self, transaction=None):
        return types.SimpleNamespace(exists=False, to_dict=lambda: {})
    def set(self, *args, **kwargs):
        return None
    def update(self, *args, **kwargs):
        return None


class _Collection:
    def document(self, _name):
        return _Document()


class _FirestoreClient:
    def __init__(self, *args, **kwargs):
        pass
    def collection(self, _name):
        return _Collection()
    def transaction(self):
        return object()


def transactional(function):
    return function


firestore = types.ModuleType("google.cloud.firestore")
firestore.Client = _FirestoreClient
firestore.transactional = transactional
firestore.SERVER_TIMESTAMP = object()
cloud.firestore = firestore
sys.modules["google.cloud.firestore"] = firestore

kms_v1 = types.ModuleType("google.cloud.kms_v1")
kms_v1.KeyManagementServiceClient = lambda *args, **kwargs: types.SimpleNamespace()
cloud.kms_v1 = kms_v1
sys.modules["google.cloud.kms_v1"] = kms_v1
