import asyncio, sys
from bleak import BleakScanner

async def main():
    dur = 15.0
    print(f"scanning BLE for {dur}s ...")
    try:
        res = await BleakScanner.discover(timeout=dur, return_adv=True)
    except Exception as e:
        print("SCAN_ERR:", repr(e)); return

    she = []
    # res: dict addr -> (BLEDevice, AdvertisementData)
    for addr, pair in res.items():
        dev, adv = pair
        name = (dev.name or getattr(adv, "local_name", "") or "")
        rssi = getattr(adv, "rssi", "?")
        svcs = getattr(adv, "service_uuids", [])
        line = f"{addr}  rssi={rssi}  name={name!r}  svcs={svcs}"
        print(line)
        if "SHE" in name.upper():
            she.append(line)
    print("---")
    if she:
        print("FOUND SHE DEVICE(S):")
        for s in she:
            print("  ", s)
    else:
        print(f"NO 'SHE' DEVICE SEEN (total {len(res)} BLE devices visible)")

asyncio.run(main())
