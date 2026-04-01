#!/bin/bash

SERVER_IP=10.45.0.1
DURATION=20
IPERF_PORT=8037

echo "---------------------------------------------------"
echo "Starting simultaneous iperf and ping tests to $SERVER_IP"
echo "Test duration: $DURATION seconds"
echo "---------------------------------------------------"

iperf -c $SERVER_IP -p $IPERF_PORT -u -b 10M -R -t $DURATION -i 1 > ~/iperf_results.txt &
IPERF_PID=$!
echo "[*] iperf started (PID: $IPERF_PID)"

ping -c "$DURATION" "$SERVER_IP" > ~/ping_results.txt &
PING_PID=$!
echo "[*] ping started  (PID: $PING_PID)"

echo "---------------------------------------------------"
echo "Tests are running... please wait."

wait $IPERF_PID
wait $PING_PID

echo "Done!"
echo "Check 'iperf_results.txt' and 'ping_results.txt' for the data."