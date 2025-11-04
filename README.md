# **ecobee TOU Scheduler (ecobee\_TOU.sh)**

## **Motivation**

I created this script because the native Ecobee mobile/web apps and common smart-home automation platforms (like Google Home, Alexa, or Apple HomeKit) do not provide a way to schedule timed HVAC mode switches that specifically force the auxiliary gas furnace.  
My electric utility uses a **Time-of-Use (TOU)** plan where electricity costs spike to nearly **3x** the off-peak rate during the evening peak (typically 5:00 PM \- 9:00 PM). My financial analysis showed that operating the gas furnace (via Ecobee's auxHeatOnly / "AUX" mode) is significantly more cost-effective during this specific period than using the electric heat pump. To bridge this functional gap and enable automated cost savings, this script lets you schedule the necessary exact mode changes against an Ecobee thermostat.

## **Overview**

ecobee\_TOU.sh is a small Bash helper script that switches a target Ecobee thermostat between operational modes (HEAT, OFF, AUX, COOL, AUTO). The script uses the Ecobee REST API and reads credentials from a local ecobee.conf JSON file.  
Although the examples below I use a Synology server to run scheduled tasks, the approach is generalizable to any continuously-running system that can schedule jobs (home/server NAS, Raspberry Pi, cloud VM, etc.). The script has been tested on Unix-like systems; it should also work on macOS and on Windows environments that provide Bash/curl/python3 (for example WSL, Cygwin, or Git Bash), though native Windows usage has not been directly tested.

### **Example Real-World Use (your setup)**

* A Synology server calls this script at **17:00** to set the thermostat to **AUX** (forcing the gas furnace).  
* When the expensive electricity period ends, the Synology server runs the script again with **HEAT** to return to the electric heat pump.  
* This is done because the electricity rate spikes to \~3× during the TOU period and you want to prefer the gas furnace only for that interval.

## **Prerequisites**

* **Linux / macOS** with Bash  
* **curl** (used for HTTP requests)  
* **python3** (used for small JSON parsing tasks, required for robustness)  
* **Executable permission** on the script: chmod \+x ecobee\_TOU.sh

### **Additional useful tools**

* **jq** — used by the script to pretty-print JSON during \--probe-thermostats. If you don't have jq the script will still work but output will be single-line JSON. Install with your package manager (e.g., sudo apt install jq).  
* **mktemp** and standard coreutils — used internally by the script; typically available on any modern Unix-like system.

## **Getting Ecobee API credentials**

1. **Create a developer application**  
   * Go to https://developer.ecobee.com/ and sign in.  
   * Create a new application to obtain an API Key (also called "client\_id"). This is your API\_KEY.  
2. **Authorize the application and obtain tokens**  
   * Follow Ecobee's OAuth flow to authorize your app for your account. See Ecobee's examples, for instance: https://developer.ecobee.com/home/developer/api/examples/ex1.shtml  
   * After completing the flow, you will receive an ACCESS\_TOKEN and a REFRESH\_TOKEN. The ACCESS\_TOKEN is short-lived and the REFRESH\_TOKEN is used to obtain a new access token.  
3. **Store credentials locally**  
   * Create a file called ecobee.conf in the same directory as ecobee\_TOU.sh. The file must be valid JSON with at least the following keys:

Example ecobee.conf (replace the values):  
{  
  "API\_KEY": "your\_ecobee\_api\_key\_here",  
  "ACCESS\_TOKEN": "your\_current\_access\_token\_here",  
  "REFRESH\_TOKEN": "your\_refresh\_token\_here",  
  "AUTHORIZATION\_CODE": "(optional if you keep it)"  
}

Make sure this file is readable only by you:  
chmod 600 ecobee.conf

## **How the script works (important notes)**

* The script currently has the thermostat identifier hard-coded to the **Downstairs** thermostat (ID 421872778226). You should **change this** in the script's source.  
* Modes accepted by the script (case-insensitive): HEAT, OFF, AUX, COOL, AUTO.  
  * **AUX maps to Ecobee's auxHeatOnly setting.**  
* The script supports a safe **dry-run mode**: \--dry-run (or \-n) prints the JSON payload that would be sent without making network calls.  
* The script accepts a verbose flag \-v or \--verbose which enables verbose API output (equivalent to curl \-v) useful for debugging headers and connection details.  
* The script automatically attempts to refresh the ACCESS\_TOKEN using the REFRESH\_TOKEN if it receives a **401/expired-token** response while performing a POST request. On a successful refresh during a live action, it writes the new token(s) back to ecobee.conf so future calls continue working.  
* The \--test-connection option performs a read-only API call to verify that the ACCESS\_TOKEN works (and will attempt a refresh if it doesn't). The test does **not** write refreshed tokens back into ecobee.conf (it is read-only by design).

## **New / Diagnostic Options**

* **\--probe-thermostats** — Queries the Ecobee API and prints the raw thermostat JSON response (pretty-printed if jq is available). This is useful to discover thermostat identifiers, names, remote sensors, current runtime and settings.  
  * Example: ecobee\_TOU.sh \--probe-thermostats | jq .  
* **\--test-connection** — Performs a minimal read-only API request (thermostat selection) to verify token validity. If the access token is expired, the script will attempt a token refresh but will **not modify ecobee.conf** during this test.  
* **\--get-current-mode** — Query the (hard-coded) target thermostat and print a concise, human-friendly line showing the thermostat name, identifier, and its current hvacMode.  
  * Example Output: Downstairs (421872778226): heat

## **Basic Usage**

From the repository root (where ecobee.conf lives):

| Action | Command |
| :---- | :---- |
| **Dry-run (see payload only)** | ./ecobee\_TOU.sh AUX \--dry-run |
| **Real change (set mode to AUX)** | ./ecobee\_TOU.sh AUX |
| **Test connectivity and token validity** | ./ecobee\_TOU.sh \--test-connection |
| **Probe thermostats (show raw JSON)** | ./ecobee\_TOU.sh \--probe-thermostats |
| **Get current mode only** | ./ecobee\_TOU.sh \--get-current-mode |
| **Run real change & log curl verbose output** | ./ecobee\_TOU.sh OFF \-v 2\>curl\_verbose.log |

### **Concrete usage examples**

* **Synology Task Scheduler (simple command example)**  
  * Run AUX at 17:00 every weekday: /bin/bash \-lc "/path/to/ecobee\_TOU.sh AUX 2\>&1 | logger \-t ecobee\_TOU"  
  * Restore HEAT after the TOU period (example 20:00): /bin/bash \-lc "/path/to/ecobee\_TOU.sh HEAT 2\>&1 | logger \-t ecobee\_TOU"  
* **Cron examples (if you prefer crontab)**  
  * Force AUX at 17:00 every day: 0 17 \* \* \* /bin/bash \-lc "/path/to/ecobee\_TOU.sh AUX \>\> /var/log/ecobee\_TOU.log 2\>&1"  
  * Restore HEAT at 20:00 every day: 0 20 \* \* \* /bin/bash \-lc "/path/to/ecobee\_TOU.sh HEAT \>\> /var/log/ecobee\_TOU.log 2\>&1"

## **Behavior and Safety**

* The script prints helpful messages for success or failure. On success it prints:  
  * Success: mode set to \<ecobee-mode\> for thermostat 'Downstairs'.  
* If the access token is expired, the script will attempt a refresh during the POST flow and will update ecobee.conf with the new tokens.  
* **Always use \--dry-run** when testing new modes or scripts on a schedule until you're confident in behavior.

### **Exit Codes (Summary)**

| Code | Meaning |
| :---- | :---- |
| **0** | Success (operation succeeded or test passed) |
| **2** | Usage / missing configuration file / bad arguments |
| **3** | Access token expired and no refresh token available (during POST) |
| **4** | Token refresh failed |
| **5** | API returned non-zero status (operation failed) |
| **6** | HTTP error / other |

## **Customization**

* **Change Thermostat Target**: Edit ecobee\_TOU.sh and change the line below to whatever your thermostat's ID is (use \--probe-thermostats to find it):

THERMOSTAT\_ID="123456789"

* **Token Update Behavior**: If you prefer **not** to write refreshed tokens back into ecobee.conf (e.g., if you manage them externally), you can modify the write\_config function inside the script to print the new tokens instead of overwriting the file.

## **Troubleshooting**

* **"Invalid selection. Selection missing."** — means the thermostat selection in the JSON payload did not match any thermostats. Verify the THERMOSTAT\_ID in the script is correct using \--probe-thermostats.  
* If you see JSON parse errors, ensure python3 is in PATH and ecobee.conf is valid JSON.  
* If the script cannot refresh the token, re-run the Ecobee authorization flow to obtain fresh tokens.

## **Security**

* ecobee.conf contains sensitive tokens. Keep its permissions restrictive and **avoid committing it to version control.**

chmod 600 ecobee.conf  
git update-index \--assume-unchanged ecobee.conf \# if already tracked

## **Disclaimer and Protections**

This script is provided "as‑is" and is shared as an altruistic effort. I cannot be held responsible for any damage, data loss, service disruption, or harm to your Ecobee thermostat or other systems that may result from using it, whether foreseen or unforeseen. **Use at your own risk.**

### **Recommended Common Protections and Safe Practices**

* Always test with **\--dry-run** (or **\--probe-thermostats** / **\--test-connection**) before performing live changes to inspect payloads and responses.  
* Restrict ecobee.conf permissions (chmod 600\) and avoid storing tokens in shared or tracked repositories.  
* Run scheduled jobs as a **least-privilege user** (do not run as root) and limit what the scheduled task can access.  
* Pipe output to a log and rotate logs; review logs after initial runs to confirm behavior.  
* Verify connectivity and tokens immediately prior to a scheduled live change (use **\--test-connection**).
