"""A fake Hue Play HDMI Sync Box for testing the box driver without a box (#547, docs/fakebox-design.md).

  model.py    the box's state machine, pure (no I/O): every request, event and time rule of §2
  server.py   the box over real HTTPS, several boxes on their own ports, the faults of §2
  control.py  the control API on 127.0.0.1 that tools/fakebox.py drives
  ca.py       the per-VM CA and one leaf per box
  mdns.py     the _huesync._tcp.local answer

Standard library only (plus the openssl command for the CA); python3 -I safe.
"""
