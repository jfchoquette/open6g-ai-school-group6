"""
Sierra 5G traffic generation script.

If the UE is detected to be configured for eMBB -> Run ping tests only

If the UE is detected to be configured for URLCC -> Run

Usage:
  python school_sierra_controller.py
  python school_sierra_controller.py --reboot       # reboot sierra first
"""
import argparse
import asyncio
import os
import signal
import sys
import enum
import re
sys.path.insert(0, '.')

from sierra_control import SierraControl

SERVER_URL = "wss://sierra-server-sierras.apps.tenoran.automation.otic.open6g.net"
TARGET_IMSI = os.environ.get("TARGET_IMSI")

EMBB_IMSI = os.environ.get("EMBB_IMSI", "001080000150191") # Sierra 1

URLLC_IMSI = os.environ.get("URLLC_IMSI", "001080000150192") # Sierra 2

WRITABLE_DIRECTORY = "/mnt/shared/open6g-ai-school-group6/test-runs"

class SierraMock():
    """
    Masks Sierra API calls do nothing.
    Useful to test the results collection and script pipelines without using the actual limited hardware.
    """
    async def delete_pdu(self, imei):
        print(f"PDU deleted for device: {imei}")

    async def enable_airplane_mode(self, imei):
        print(f"Airplane mode enabled for: {imei}")

    async def disable_airplane_mode(self, imei):
        print(f"Airplane mode disabled for: {imei}")

    async def disconnect(self, imei):
        print(f"Device {imei} disconnected.")

    async def connect(self, imei):
        print(f"Device {imei} connected.")

    async def ping_test(self, imei, destination="8.8.8.8"):
        """Performs a network ping test."""
        print(f"Pinging {destination} from {imei}...")

    async def execute_command(self, imei, command):
        """Executes a raw AT command or shell command."""
        print(f"Executing '{command}' on {imei}")

    async def reboot_sierra(self, imei):
        """Triggers a reboot of the Sierra module."""
        print(f"Rebooting device {imei}...")

    async def create_pdu(self, imei, timeout=30.0):
        """Creates a PDU session within the specified timeout."""
        print(f"Creating PDU for {imei} with timeout {timeout}s")
        return True

class CQI(enum.Enum):
    eMBB = enum.auto()
    URLLC = enum.auto()

    @staticmethod
    def get() -> 'CQI':
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
        sys.exit(1)

    @property
    def pdu_lock_file_path(self):

        cqi = self.as_string()
        return f"{WRITABLE_DIRECTORY}/{cqi}-pdu.lock"

    @property
    def other_ue_lock_file_path(self):
        other_cqi = None

        if self == CQI.eMBB:
            other_cqi = CQI.URLLC
        
        if self == CQI.URLLC:
            other_cqi = CQI.eMBB

        other_cqi_name = other_cqi.as_string()
        return f"{WRITABLE_DIRECTORY}/{other_cqi_name}-pdu.lock"

    def as_string(self):
        if self == CQI.eMBB:
            return "embb"

        if self == CQI.URLLC:
            return "urlcc"

        print("FATAL: Invalid 5QI")
        sys.exit(1)

def parse_args():
    parser = argparse.ArgumentParser(description="Sierra 5G traffic generation script")
    parser.add_argument("--reboot", action="store_true",
                        help="Reboot the Sierra modem before starting")
    parser.add_argument("--ping_rounds", type=int, default=6, help="How many rounds of pings to execute, if the UE does ping tests (there are 10 seconds of pings per round)")
    parser.add_argument("--mock", action="store_true", help="If true, do not execute anything on the sierra or touch lock files. For testing management script logic only.")
    parser.add_argument("--scheduler_file_name", type=str, default="unknown_scheduler", help="Name of scheduler script for results aggregation.")
    args = parser.parse_args()
    return args


async def graceful_cleanup(control, imei, args):
    """Delete PDU session and enable airplane mode before exiting."""
    print("\n[CTRL+C] Graceful shutdown — cleaning up...")
    try:
        await cleanup(control, imei, args.mock())
    except Exception as e:
        print(f"[CTRL+C] Cleanup error: {e}")
    print("[CTRL+C] Cleanup complete.")

async def cleanup(control, imei, mock=False):
    print("\nCleaning up...")

    if not mock:
        if os.path.exists(CQI.get().pdu_lock_file_path):
            os.remove(CQI.get().pdu_lock_file_path)

    await asyncio.sleep(0.5)
    print("Deleting PDU session...")
    await control.delete_pdu(imei)
    await asyncio.sleep(5)
    print("Enabling airplane mode...")
    await control.enable_airplane_mode(imei)
    await asyncio.sleep(5)
    print("Disconnecting...")
    await control.disconnect(imei)
    
async def get_imei(control, mock=False):
    """
    Returns IMEI
    """
    if mock:
        return "MOCK"

    devices = await control.get_devices()
    if not devices:
        print("FATAL: No devices available!")
        sys.exit(1)

    imei = None
    for dev_imei in devices:
        info = await control.get_device_info(dev_imei)
        if info and info["status"].get("active_imsi") == TARGET_IMSI:
            imei = dev_imei
            break

    if not imei:
        print(f"FATAL: Device with IMSI {TARGET_IMSI} not found!")
        sys.exit(1)
    print(f"Found device: IMEI {imei} (IMSI {TARGET_IMSI})")

    return imei

async def wait_for_other_ue_pdu_lock(mock=False):
    print("Waiting for other UE to create PDU session before running tests...")
    if mock:
        return

    while True:
        print("waiting for ", CQI.get().other_ue_lock_file_path)
        if os.path.exists(CQI.get().other_ue_lock_file_path):
            break
        await asyncio.sleep(0.5)

async def main(args):
    if not TARGET_IMSI:
        print("ERROR: TARGET_IMSI environment variable not set!")
        return


    if args.mock:
        control = SierraMock()
    else:
        control = SierraControl(SERVER_URL)

    imei = await get_imei(control, mock=args.mock)

    try:
        await control.connect(imei)

        await do_pre_run_cleanup(control, imei, args)

        await create_pdu_session(control, imei)

        await wait_for_other_ue_pdu_lock(mock=args.mock)

        await run_tests(control, imei)

        await cleanup(control, imei)

        print("Done!")

    except asyncio.CancelledError:
        await graceful_cleanup(control, imei, args)

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

async def run_tests_for_urlcc(control, imei, args):
    print("\nURLCC: Running ping test to 10.45.0.1...")
    ping_loops = 3
    
    for i in range(ping_loops):
        ping_ok, ping_output = await control.ping_test(imei, "10.45.0.1", timeout=30.0)
        print(f"Ping result {i}: {'OK' if ping_ok else 'FAILED'}")
        if ping_output:
            print(ping_output)
        time_values = re.findall(r'time=([0-9.]+)', ping_output)

        results_dir = find_results_dir(args.scheduler_file_name)
        with open(f'{WRITABLE_DIRECTORY}/{results_dir}/urlcc_ping_results.csv', 'w') as f:
            f.write("time(ms)\n")
            f.write('\n'.join(time_values))

async def run_tests_for_embb(control, imei, args):
    """
    iperf traffic (UDP downlink, 100Mbps, 20s)
    """
    print("\neMBB: Starting iperf traffic (UDP DL 100Mbps, 20s)...")
    iperf_ok, iperf_output = await control.execute_command(
        imei,
        "iperf -c 10.45.0.1 -p 8037 -u -b 100M -R -t 20 -i 1",
        timeout=60.0
    )
    print(f"iperf result: {'OK' if iperf_ok else 'FAILED'}")
    if iperf_output:
        print(iperf_output)
        results_dir = find_results_dir(args.scheduler_file_name)
        with open(f'{WRITABLE_DIRECTORY}/{results_dir}/embb_iperf_results.csv', 'w') as f:
            f.write("Interval_Start(sec),Interval_End(sec),Transfer,Transfer_Unit,Bandwidth(Mbits/sec),Jitter(ms),Lost_Datagrams,Total_Datagrams,Packet_Loss(%)\n")

            for line in iperf_output.splitlines():
                line = line.replace('\xa0', ' ')  # remove non-breaking spaces

                match = re.search(
                    r'\[\s*\*?1\]\s+'
                    r'([0-9.]+)-([0-9.]+)\s+sec\s+'
                    r'([0-9.]+)\s+(MBytes|KBytes)\s+'
                    r'([0-9.]+)\s+Mbits/sec\s+'
                    r'([0-9.]+)\s+ms\s+'
                    r'([0-9]+)/([0-9]+)\s+\(([0-9.]+)%\)',
                    line
                )

                if match:
                    interval_start = match.group(1)
                    interval_end = match.group(2)
                    transfer = match.group(3)
                    transfer_unit = match.group(4)
                    bandwidth = match.group(5)
                    jitter = match.group(6)
                    lost = match.group(7)
                    total = match.group(8)
                    loss_pct = match.group(9)

                    f.write(f"{interval_start},{interval_end},{transfer},{transfer_unit},{bandwidth},{jitter},{lost},{total},{loss_pct}\n")

async def run_tests(control, imei, args):
    if CQI.get() == CQI.eMBB:
        await run_tests_for_embb(control, imei, args)
    
    if CQI.get() == CQI.URLLC:
        await run_tests_for_urlcc(control, imei, args)

async def do_pre_run_cleanup(control, imei, args):

    if not args.mock:
        if os.path.exists(CQI.get().pdu_lock_file_path):
            os.remove(CQI.get().pdu_lock_file_path)

            if CQI.get() == CQI.URLLC:
                create_results_dir(args.scheduler_file_name)

    if args.reboot:
        print("\n[REBOOT] Rebooting Sierra...")
        await control.reboot_sierra(imei)
        print("Sierra rebooted.")

    # Clean up any stale PDU session
    print("\nDeleting any existing PDU session...")
    await control.delete_pdu(imei)
    print("Waiting 30s for cleanup...")
    sleep_seconds = 15 if not args.mock else 0
    await asyncio.sleep(sleep_seconds)

    # Disable airplane mode
    print("Disabling airplane mode...")
    await control.disable_airplane_mode(imei)
    await asyncio.sleep(sleep_seconds)

async def create_pdu_session(control, imei):
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
    with open(CQI.get().pdu_lock_file_path, 'w') as lock:
        lock.write(f"Exists: {TARGET_IMSI}\n")

def create_results_dir(scheduler_name):
    """
    Directory in persistent storage to save results.
    We will arbitrarily have URLCC runner create this, for simplicity.
    """
    counter = 1
    base_name = scheduler_name
    dir_name = f"{base_name}-{counter}"

    while os.path.exists(dir_name):
        counter += 1
        dir_name = f"{base_name}-{counter}"

    try:
        os.makedirs(dir_name)
        print(f"Successfully created: {dir_name}")
        return dir_name
    except OSError as e:
        print(f"Error creating directory {dir_name}: {e}")
        return None
    
def find_results_dir(scheduler_name) -> str:
    """
    """
    counter = 1
    base_name = scheduler_name
    dir_name = f"{base_name}-{counter}"

    while os.path.exists(dir_name):
        counter += 1
        dir_name = f"{base_name}-{counter}"

    counter -= 1
    return dir_name

def save_results():
    """
    Saves results from test run.
    """
    
    # Create test run directory (<scheduler_file_name>-<nextid>/)
    # Write CSV
    
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