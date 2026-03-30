"""
Sierra 5G traffic generation script.

Usage:
  python school_sierra_controller.py                # PDU up for 30s, no tests
  python school_sierra_controller.py --hold 120     # keep PDU active 120s (15-300)
  python school_sierra_controller.py --reboot       # reboot sierra first
  python school_sierra_controller.py --ping         # run ping tests
  python school_sierra_controller.py --iperf        # run iperf traffic test
  python school_sierra_controller.py --retries 5    # try PDU creation up to 5 times (1-10)
"""
import argparse
import asyncio
import os
import signal
import sys
sys.path.insert(0, '.')

from sierra_control import SierraControl

SERVER_URL = "wss://sierra-server-sierras.apps.tenoran.automation.otic.open6g.net"
TARGET_IMSI = os.environ.get("TARGET_IMSI")


def parse_args():
    parser = argparse.ArgumentParser(description="Sierra 5G traffic generation script")
    parser.add_argument("--reboot", action="store_true",
                        help="Reboot the Sierra modem before starting")
    parser.add_argument("--hold", type=int, default=30, metavar="SECONDS",
                        help="Keep PDU session active for SECONDS after tests (15-300, default: 30)")
    parser.add_argument("--ping", action="store_true",
                        help="Run the ping test")
    parser.add_argument("--iperf", action="store_true",
                        help="Run the iperf test")
    parser.add_argument("--retries", type=int, default=1, metavar="N",
                        help="Number of PDU session creation attempts (1-10, default: 1)")
    args = parser.parse_args()
    if args.hold < 15 or args.hold > 300:
        parser.error("--hold must be between 15 and 300 seconds")
    if args.retries < 1 or args.retries > 10:
        parser.error("--retries must be between 1 and 10")
    return args


async def graceful_cleanup(control, imei):
    """Delete PDU session and enable airplane mode before exiting."""
    print("\n[CTRL+C] Graceful shutdown — cleaning up...")
    try:
        await asyncio.sleep(0.5)
        print("Deleting PDU session...")
        await control.delete_pdu(imei)
        await asyncio.sleep(5)
        print("Enabling airplane mode...")
        await control.enable_airplane_mode(imei)
        await asyncio.sleep(5)
        print("Disconnecting...")
        await control.disconnect(imei)
    except Exception as e:
        print(f"[CTRL+C] Cleanup error: {e}")
    print("[CTRL+C] Cleanup complete.")


async def main(args):
    if not TARGET_IMSI:
        print("ERROR: TARGET_IMSI environment variable not set!")
        return

    control = SierraControl(SERVER_URL)

    # 1. Find device by IMSI
    devices = await control.get_devices()
    if not devices:
        print("No devices available!")
        return

    imei = None
    for dev_imei in devices:
        info = await control.get_device_info(dev_imei)
        if info and info["status"].get("active_imsi") == TARGET_IMSI:
            imei = dev_imei
            break

    if not imei:
        print(f"Device with IMSI {TARGET_IMSI} not found!")
        return

    print(f"Found device: IMEI {imei} (IMSI {TARGET_IMSI})")

    try:
        # 2. Connect
        await control.connect(imei)

        # 3. Reboot if requested
        if args.reboot:
            print("\n[REBOOT] Rebooting Sierra...")
            await control.reboot_sierra(imei)
            print("Sierra rebooted.")

        # 4. Clean up any stale PDU session
        print("\nDeleting any existing PDU session...")
        await control.delete_pdu(imei)
        print("Waiting 30s for cleanup...")
        await asyncio.sleep(30)

        # 5. Disable airplane mode
        print("Disabling airplane mode...")
        await control.disable_airplane_mode(imei)
        await asyncio.sleep(15)

        # 6. Create PDU session (with retries)
        pdu_ok = False
        for attempt in range(1, args.retries + 1):
            print(f"\nCreating PDU session (attempt {attempt}/{args.retries})...")
            pdu_ok = await control.create_pdu(imei, timeout=30.0)
            if pdu_ok:
                break
            print(f"Attempt {attempt} failed.")
            if attempt < args.retries:
                print("Cleaning up before next attempt...")
                await control.delete_pdu(imei)
                await asyncio.sleep(5)

        if not pdu_ok:
            print("ERROR: PDU creation failed after all attempts! Cleaning up...")
            await control.enable_airplane_mode(imei)
            await control.disconnect(imei)
            return

        print("PDU session active")

        # 7. Ping test
        if args.ping:
            print("\nRunning ping test to 10.45.0.1...")
            ping_ok, ping_output = await control.ping_test(imei, "10.45.0.1", timeout=30.0)
            print(f"Ping result: {'OK' if ping_ok else 'FAILED'}")
            if ping_output:
                print(ping_output)

        # 8. iperf traffic (UDP downlink, 100Mbps, 20s)
        if args.iperf:
            print("\nStarting iperf traffic (UDP DL 100Mbps, 20s)...")
            iperf_ok, iperf_output = await control.execute_command(
                imei,
                "iperf -c 10.45.0.1 -p 8037 -u -b 100M -R -t 20 -i 1",
                timeout=60.0
            )
            print(f"iperf result: {'OK' if iperf_ok else 'FAILED'}")
            if iperf_output:
                print(iperf_output)

        # 9. Hold PDU session active
        print(f"\nHolding PDU session active for {args.hold}s...")
        await asyncio.sleep(args.hold)
        print("Hold period complete.")

        # 10. Cleanup
        print("\nCleaning up...")
        await control.delete_pdu(imei)
        await asyncio.sleep(30)
        await control.enable_airplane_mode(imei)
        await asyncio.sleep(30)
        print("Done!")

    except asyncio.CancelledError:
        await graceful_cleanup(control, imei)

    except Exception as e:
        print(f"\nError: {e}")
        try:
            await control.delete_pdu(imei)
            await asyncio.sleep(30)
            await control.enable_airplane_mode(imei)
            await asyncio.sleep(30)
        except Exception:
            pass

    finally:
        try:
            await control.disconnect(imei)
        except Exception:
            pass


def run():
    args = parse_args()
    loop = asyncio.new_event_loop()
    main_task = loop.create_task(main(args))
    loop.add_signal_handler(signal.SIGINT, main_task.cancel)
    try:
        loop.run_until_complete(main_task)
    except asyncio.CancelledError:
        pass
    finally:
        loop.close()

if __name__ == "__main__":
    run()