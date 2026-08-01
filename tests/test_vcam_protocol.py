import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "desktop"))

from vcam_protocol import (  # noqa: E402
    HEADER,
    KIND_JPEG_VIDEO,
    MAGIC,
    VERSION,
    pack_packet,
    unpack_packet,
)


class ProtocolTests(unittest.TestCase):
    def test_round_trip_is_network_order_and_lossless(self) -> None:
        payload = b"\xff\xd8fake-jpeg\xff\xd9"
        packet = pack_packet(KIND_JPEG_VIDEO, payload, timestamp_us=123456789)

        self.assertEqual(len(packet), HEADER.size + len(payload))
        self.assertEqual(packet[:4], MAGIC)
        self.assertEqual(packet[4], VERSION)
        self.assertEqual(unpack_packet(packet), (KIND_JPEG_VIDEO, 123456789, payload))

    def test_rejects_invalid_magic(self) -> None:
        packet = bytearray(pack_packet(KIND_JPEG_VIDEO, b"jpeg", timestamp_us=1))
        packet[:4] = b"NOPE"
        with self.assertRaisesRegex(ValueError, "magic"):
            unpack_packet(bytes(packet))

    def test_rejects_empty_payload(self) -> None:
        with self.assertRaisesRegex(ValueError, "empty"):
            pack_packet(KIND_JPEG_VIDEO, b"")


if __name__ == "__main__":
    unittest.main()
