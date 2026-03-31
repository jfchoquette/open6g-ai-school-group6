"""
Sierra 5G traffic generation script.

If the UE is detected to be configured for eMBB -> Run ping tests only

If the UE is detected to be configured for URLCC -> Run

Usage:
  python school_sierra_controller.py                # PDU up for 30s, no tests
  python school_sierra_controller.py --reboot       # reboot sierra first
"""
import argparse
import asyncio
import os
import signal
import sys
import enum
sys.path.insert(0, '.')

from sierra_control import SierraControl

SERVER_URL = "wss://sierra-server-sierras.apps.tenoran.automation.otic.open6g.net"
TARGET_IMSI = os.environ.get("TARGET_IMSI")

EMBB_IMSI = os.environ.get("EMBB_IMSI", "001080000150191") # Sierra 1

URLLC_IMSI = os.environ.get("URLLC_IMSI", "001080000150192") # Sierra 2

class CQI(enum.Enum):
    eMBB = enum.auto()
    URLLC = enum.auto()

def ue_5qi():
    """
    Decides 5QI to help automatically determine which tests to run and format output.
    Assumes that the IMSIs have already been configured accordingly in the core.
    Hard-coded defaults should be fine.

    Returns:
        CQI: 5QI for given IMSI
    """

    if TARGET_IMSI == EMBB_IMSI:
        return CQI.eMBB
    
    if TARGET_IMSI == URLLC_IMSI:
        return CQI.URLLC

    print(f"FATAL: {TARGET_IMSI} is not a configured IMSI!")

def parse_args():
    parser = argparse.ArgumentParser(description="Sierra 5G traffic generation script")
    parser.add_argument("--reboot", action="store_true",
                        help="Reboot the Sierra modem before starting")
    args = parser.parse_args()
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

        # 6. Create PDU session (infinite retries)
        pdu_ok = False
        attempt = 1
        while True:
            print(f"\nCreating PDU session (attempt {attempt})...")
            pdu_ok = await control.create_pdu(imei, timeout=30.0)
            if pdu_ok:
                break
            print(f"Attempt {attempt} failed. Cleaning up before next attempt...")
            await control.delete_pdu(imei)
            await asyncio.sleep(5)
            attempt += 1

        print("\n*** PDU session active ***")
        
        # TODO
        # WAIT HERE UNTIL SOME EVENT (MANUAL INTERVENTION)
        # OR TIMER
        # OR WAIT FOR BOTH UEs
        
        # Pause and wait for user input without blocking the asyncio event loop
        loop = asyncio.get_running_loop()
        
        await loop.run_in_executor(None, input, "Press Enter to proceed with tests...\n")

        await run_tests(control, imei)

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
        
async def run_tests_for_embb(control, imei):
    print("\neMBB: Running ping test to 10.45.0.1...")
    ping_ok, ping_output = await control.ping_test(imei, "10.45.0.1", timeout=30.0)
    print(f"Ping result: {'OK' if ping_ok else 'FAILED'}")
    if ping_output:
        print(ping_output)

async def run_tests_for_urlcc(control, imei):
    """
    iperf traffic (UDP downlink, 100Mbps, 20s)
    """
    print("\nURLCC: Starting iperf traffic (UDP DL 100Mbps, 20s)...")
    iperf_ok, iperf_output = await control.execute_command(
        imei,
        "iperf -c 10.45.0.1 -p 8037 -u -b 100M -R -t 20 -i 1",
        timeout=60.0
    )
    print(f"iperf result: {'OK' if iperf_ok else 'FAILED'}")
    if iperf_output:
        print(iperf_output)

async def run_tests(control, imei):
    if ue_5qi() == CQI.eMBB:
        await run_tests_for_embb(control, imei)
    
    if ue_5qi() == CQI.URLLC:
        await run_tests_for_urlcc(control, imei)

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