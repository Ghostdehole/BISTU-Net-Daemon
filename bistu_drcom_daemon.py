#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Dr.COM Auto-Authentication Daemon & Device Manager (Ultimate Edition)
--------------------------------------------------------------------
A highly optimized, stateful daemon for bypassing Captive Portals, 
managing dual-domain failover, handling interface egress binding, 
and providing an interactive CLI for remote device termination.

Target: Beijing Information Science & Technology University (BISTU)
"""

import os
import sys
import json
import struct
import hashlib
import socket
import time
import random
import re
import logging
import argparse
from typing import Dict, Optional, Any
from dataclasses import dataclass

import requests
from requests.adapters import HTTPAdapter
import urllib3

# Suppress insecure HTTPS request warnings for captive portals
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Pre-compiled regex for JSONP response extraction to optimize CPU cycles
JSONP_PATTERN = re.compile(r'^\s*\w+\((.*)\)\s*;?\s*$', re.DOTALL)


# ==========================================
# Configuration Definitions
# ==========================================
DEFAULT_CONFIG: Dict[str, Any] = {
    "username": "",                     
    "password": "",                     
    "mac_address": "",                  
    
    "campus_domains":["lan.bistu.edu.cn", "wlan.bistu.edu.cn"],
    "internet_test_url": "http://captive.apple.com/hotspot-detect.html", 
    "enable_force_kick": True,          
    "bind_interface_ip": "",            
    
    "check_interval": 15,               
    "login_cooldown": 5,                
    "max_retries": 3,                   
    "retry_backoff": 2,                 
    
    "pid": "1",                         
    "calg": "12345678",                 
    "enable_log_file": True,            
    "log_level": "INFO"                 
}

# ==========================================
# Telemetry & Logging
# ==========================================
def setup_logger(config: Dict[str, Any]) -> logging.Logger:
    """Initialize robust logging telemetry."""
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    
    if config.get("enable_log_file"):
        log_file = os.path.join(os.path.dirname(__file__), "drcom_daemon.log")
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s[%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
        )
        handlers.append(file_handler)

    logging.basicConfig(
        level=getattr(logging, config.get("log_level", "INFO").upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers
    )
    return logging.getLogger("DrCOM_Daemon")


# ==========================================
# Core Networking & State Management
# ==========================================
@dataclass
class DaemonState:
    """State machine container for the authentication daemon."""
    last_login_time: float = 0.0
    last_network_state: Optional[str] = None   
    consecutive_failures: int = 0      
    current_gateway: str = ""  


class EgressBindingAdapter(HTTPAdapter):
    """Force socket binding to a specific network interface to bypass virtual proxies."""
    def __init__(self, source_address: str, **kwargs: Any) -> None:
        self.source_address = source_address
        super().__init__(**kwargs)

    def init_poolmanager(self, connections: int, maxsize: int, block: bool = False, **pool_kwargs: Any) -> None:
        pool_kwargs['source_address'] = (self.source_address, 0)
        super().init_poolmanager(connections, maxsize, block, **pool_kwargs)


class DrComDaemon:
    """Main orchestration class for Dr.COM captive portal bypass and device management."""

    def __init__(self) -> None:
        self.config = self._load_configuration()
        self.logger = setup_logger(self.config)
        self.state = DaemonState(current_gateway=self.config["campus_domains"][0])
        
        self.last_bind_ip: Optional[str] = None
        self.session: requests.Session = self._create_bypassed_session()

    def _load_configuration(self) -> Dict[str, Any]:
        """Load configuration from file and inject environment variables."""
        cfg = DEFAULT_CONFIG.copy()
        config_path = os.path.join(os.path.dirname(__file__), "config.json")
        
        if os.path.exists(config_path):
            try:
                with open(config_path, "r", encoding="utf-8") as f:
                    cfg.update(json.load(f))
            except Exception as e: 
                print(f"[Warning] Failed to parse config.json: {e}")

        cfg["username"] = os.environ.get("DRCOM_USER", cfg["username"])
        cfg["password"] = os.environ.get("DRCOM_PASS", cfg["password"])
        cfg["mac_address"] = os.environ.get("DRCOM_MAC", cfg.get("mac_address", ""))

        if not cfg["username"] or not cfg["password"]:
            raise ValueError("Critical: Authentication credentials missing. Check config.json or ENV.")
        return cfg

    def _create_bypassed_session(self, bind_ip: Optional[str] = None) -> requests.Session:
        """Instantiate a pristine session ignoring OS-level proxy settings."""
        if hasattr(self, 'session') and self.session:
            self.session.close() 
            
        session = requests.Session()
        session.trust_env = False  
        session.proxies = {"http": None, "https": None, "all": None}
        
        if bind_ip:
            adapter = EgressBindingAdapter(bind_ip)
            session.mount('http://', adapter)
            session.mount('https://', adapter)
        return session

    def _get_physical_ip(self) -> str:
        """Probe the routing table for the true physical egress IP, bypassing TUN interfaces."""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("119.29.29.29", 80)) 
                ip = s.getsockname()[0]
            
            # Subnet penetration for Clash/Sing-box TUN or VM internal networks
            if ip.startswith("198.18.") or ip.startswith("198.19.") or ip.startswith("172."):
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s_fallback:
                    s_fallback.connect((self.state.current_gateway, 80)) 
                    ip = s_fallback.getsockname()[0]
            return ip
        except Exception: 
            return ""

    def _encrypt_payload(self) -> str:
        """Construct the Dr.COM specific MD5 hashed password."""
        raw_str = f"{self.config['pid']}{self.config['password']}{self.config['calg']}"
        md5_hash = hashlib.md5(raw_str.encode("utf-8")).hexdigest()
        return f"{md5_hash}{self.config['calg']}{self.config['pid']}"

    def _inject_mac_address(self, params: Dict[str, str]) -> None:
        """Inject user-defined MAC address into the payload structure."""
        mac = self.config.get("mac_address", "")
        if mac:
            clean_mac = mac.replace("-", "").replace(":", "").upper()
            params["wlan_user_mac"] = clean_mac
            params["mac"] = clean_mac
        else:
            params["wlan_user_mac"] = "000000000000"

    def _check_campus_environment(self) -> bool:
        """Verify presence within the campus intranet via domain probing."""
        for domain in self.config["campus_domains"]:
            try:
                self.session.head(f"http://{domain}", timeout=2, allow_redirects=False, verify=False)
                return True
            except Exception: 
                continue
        return False

    def _check_captive_portal(self) -> str:
        """Evaluate network state via Apple's Captive Portal standard probe."""
        try:
            resp = self.session.get(self.config["internet_test_url"], timeout=3, allow_redirects=False, verify=False)
            if resp.status_code == 200 and "Success" in resp.text: 
                return "INTERNET_OK"
                
            # Intercept HTTP 301/302 redirects to dynamically identify the active gateway
            if resp.status_code in (301, 302, 307):
                location = resp.headers.get("Location", "")
                for domain in self.config["campus_domains"]:
                    if domain in location:
                        if self.state.current_gateway != domain:
                            self.state.current_gateway = domain
                            self.logger.info(f"[Network Sniffer] Redirect captured. Target gateway adjusted -> {domain}")
                        return "NEED_LOGIN"
                return "NEED_LOGIN"
                
            # Fallback content inspection for transparent HTTP 200 interceptions
            if "Dr.COM" in resp.text or "bistu.edu.cn" in resp.text: 
                for domain in self.config["campus_domains"]:
                    if domain in resp.text and self.state.current_gateway != domain:
                        self.state.current_gateway = domain
                        self.logger.info(f"[Network Sniffer] Payload signature matched. Gateway adjusted -> {domain}")
                        break
                return "NEED_LOGIN"
                
            return "NO_NETWORK"
        except Exception: 
            return "NO_NETWORK"

    def _force_kick_conflict(self, conflict_ip: str) -> bool:
        """Transmit a spoofed logout packet to forcefully disconnect conflicting devices."""
        self.logger.info(f"[Session Override] Transmitting termination payload to IP: {conflict_ip}")
        url = f"https://{self.state.current_gateway}/drcom/logout"
        params = {
            "callback": "dr1002", "v4ip": conflict_ip, "0MKKey": "123456",
            "v": str(random.randint(500, 10499)), "lang": "en"
        }
        self._inject_mac_address(params)

        try:
            resp = self.session.get(url, params=params, headers={"User-Agent": "Mozilla/5.0"}, timeout=5, verify=False)
            if '"result":1' in resp.text or '"result":"ok"' in resp.text:
                self.logger.info("[Session Override] Success. Conflicting device terminated.")
                return True
        except Exception as e:
            self.logger.debug(f"Override execution failed: {e}")
        return False

    def _execute_authentication(self, local_ip: str) -> bool:
        """Handle the core authentication sequence, integrating retry mechanisms."""
        now = time.monotonic()
        if now - self.state.last_login_time < self.config["login_cooldown"]:
            return False

        use_md5 = True  
        server_url = f"https://{self.state.current_gateway}/drcom/login"

        for attempt in range(1, self.config["max_retries"] + 1):
            params = {
                "callback": "dr1001", "DDDDD": self.config["username"], "0MKKey": "123456",
                "R1": "0", "R3": "0", "R6": "0", "para": "00",
                "v4ip": local_ip, "v6ip": "", "terminal_type": "1", 
                "v": str(random.randint(500, 10499)), "lang": "en"
            }
            self._inject_mac_address(params)
            
            # Dynamic Payload Mode switching
            if use_md5:
                params["upass"] = self._encrypt_payload()
                params["R2"] = "1"
            else:
                params["upass"] = self.config["password"]
                params["R2"] = ""

            try:
                mode_str = "MD5-Hash" if use_md5 else "Plaintext"
                self.logger.info(f"[Auth] Attempt [{attempt}/{self.config['max_retries']}] via {self.state.current_gateway} ({mode_str})")
                resp = self.session.get(server_url, params=params, headers={"User-Agent": "Mozilla/5.0"}, timeout=5, verify=False)
                
                match = JSONP_PATTERN.search(resp.text)
                if match:
                    data = json.loads(match.group(1))
                    result = str(data.get("result", ""))
                    msg_code = str(data.get("msg", ""))
                    msga = str(data.get("msga", ""))
                    
                    if result in ("1", "ok") or msg_code == "15" or msga == "clientip online":
                        self.logger.info("[Auth] Payload accepted by the authorization server.")
                        self.state.last_login_time = time.monotonic()
                        return True
                        
                    err_msg = f"Unknown Exception (msg:{msg_code}, msga:{msga})"
                    
                    if msg_code in ("0", "1") and msga != "clientip online":
                        err_msg = f"Invalid Credentials (msga: {msga})"
                        if use_md5:
                            self.logger.warning(f"[Auth] {err_msg}. Triggering Plaintext payload fallback...")
                            use_md5 = False
                            time.sleep(1)
                            continue 
                        else:
                            err_msg += " (Verify suffix configuration)"
                    
                    elif msg_code == "2": 
                        conflict_ip = data.get("xip", "")
                        if self.config["enable_force_kick"] and conflict_ip:
                            self.logger.warning(f"[Auth] Session conflict detected at IP: {conflict_ip}")
                            if self._force_kick_conflict(conflict_ip):
                                time.sleep(2)
                                continue 
                    
                    elif msg_code == "3": err_msg = "Account restricted to designated subnets"
                    elif msg_code == "4": err_msg = "Quota exceeded or insufficient balance / Account suspended"
                    elif msg_code == "5": err_msg = "Account suspended by administrator"
                    
                    self.logger.warning(f"[Auth] Request rejected: {err_msg}")
                else:
                    self.logger.warning(f"[Auth] Failed to parse gateway response format.")

            except Exception as e:
                self.logger.error(f"[Auth] Transaction error: {e}")

            if attempt < self.config["max_retries"]:
                time.sleep((self.config["retry_backoff"] ** attempt) + random.uniform(0.5, 1.5))

        self.state.last_login_time = time.monotonic()
        return False

    # ==========================================
    # Interactive Device Manager (CLI)
    # ==========================================
    def launch_device_manager(self) -> None:
        """Launch the interactive CLI to query and kick online devices."""
        print("==================================================")
        print("        Dr.COM Device Management Console          ")
        print("==================================================")

        current_ip = self.config["bind_interface_ip"] or self._get_physical_ip()
        if not current_ip:
            print("[-] Error: Unable to detect a valid intranet connection.")
            return

        if current_ip and current_ip != self.last_bind_ip:
            self.session = self._create_bypassed_session(current_ip)

        print("[*] Probing optimal gateway interface...")
        self._check_captive_portal()
        print(f"[+] Active Gateway: {self.state.current_gateway}")

        print("[*] Retrieving active sessions from gateway...")

        # Combinatorial Endpoint Probing
        endpoints =[
            f"http://{self.state.current_gateway}:801/eportal/portal",
            f"https://{self.state.current_gateway}:802/eportal/portal"
        ]
        
        combinations =[
            {"login_method": "0", "find_mac": "0"},
            {"login_method": "0", "find_mac": "1"},
            {"login_method": "1", "find_mac": "0"}
        ]

        raw_devices =[]
        api_base_used = ""
        last_msg = ""
        
        for api_base in endpoints:
            for combo in combinations:
                find_url = f"{api_base}/mac/find"
                params = {
                    "callback": "dr1005",
                    "user_account": self.config["username"],
                    "login_method": combo["login_method"],
                    "find_mac": combo["find_mac"],
                    "wlan_user_ip": current_ip,
                    "jsVersion": "4.X"
                }
                self._inject_mac_address(params)

                try:
                    resp = self.session.get(find_url, params=params, headers={"User-Agent": "Mozilla/5.0"}, timeout=3, verify=False)
                    match = JSONP_PATTERN.search(resp.text)
                    if match:
                        data = json.loads(match.group(1))
                        if str(data.get("result")) in ("1", "ok"):
                            devs = data.get("list",[])
                            if devs:
                                raw_devices = devs
                                api_base_used = api_base
                                break
                        else:
                            last_msg = data.get("msg", "")
                except Exception:
                    continue
            if raw_devices:
                break
        
        if not raw_devices:
            if last_msg:
                print(f"[-] Gateway declined request: {last_msg}")
                print("[!] Note: This usually means you have NO active devices online currently.")
            else:
                print("[-] Fatal Exception: All API endpoints timed out or rejected the request.")
            return
            
        # Data Deduplication
        unique_devices =[]
        seen_fingerprints = set()
        for dev in raw_devices:
            mac = dev.get("online_mac", "Unknown").upper()
            ip = dev.get("online_ip", "Unknown")
            fingerprint = f"{mac}_{ip}"
            
            if fingerprint not in seen_fingerprints:
                seen_fingerprints.add(fingerprint)
                unique_devices.append(dev)

        print("\n---------------- ONLINE DEVICES ------------------")
        for idx, dev in enumerate(unique_devices):
            mac = dev.get("online_mac", "Unknown").upper()
            ip = dev.get("online_ip", "Unknown")
            add_time = dev.get("add_time", "")
            
            indicator = "(*)" if ip == current_ip else "   "
            time_str = f" | Logged in: {add_time}" if add_time else ""
            print(f" [{idx}] {indicator} MAC: {mac:<17} | IP: {ip:<15}{time_str}")
        print("--------------------------------------------------")
        print("(*) Indicates your current device.")
        
        while True:
            choice = input("\nEnter the ID of the device to TERMINATE (or 'q' to quit): ").strip()
            if choice.lower() == 'q' or not choice:
                print("Exiting manager.")
                return
                
            if not choice.isdigit() or int(choice) < 0 or int(choice) >= len(unique_devices):
                print("[-] Invalid ID. Please try again.")
                continue
                
            target = unique_devices[int(choice)]
            target_mac = target.get("online_mac", "").upper()
            target_ip = target.get("online_ip", "")
            
            self._terminate_device(api_base_used, target_mac, target_ip)
            break

    def _terminate_device(self, api_base: str, target_mac: str, target_ip: str) -> None:
        """Issue an unbind command to the portal API using struct packing for IPv4."""
        print(f"[*] Dispatching termination sequence to MAC: {target_mac} ...")
        unbind_url = f"{api_base}/mac/unbind"
        
        try:
            ip_int = struct.unpack("!I", socket.inet_aton(target_ip))[0]
        except Exception:
            print("[-] Invalid Target IP Format.")
            return

        kick_params = {
            "callback": "dr1006",
            "user_account": self.config["username"],
            "wlan_user_mac": target_mac,
            "wlan_user_ip": ip_int,
            "jsVersion": "4.X"
        }
        
        try:
            resp = self.session.get(unbind_url, params=kick_params, headers={"User-Agent": "Mozilla/5.0"}, timeout=10, verify=False)
            match = JSONP_PATTERN.search(resp.text)
            if match:
                res_data = json.loads(match.group(1))
                if str(res_data.get("result")) in ("1", "ok"):
                    print("[+] Target device successfully terminated and unbound!")
                else:
                    print(f"[-] Operation failed: {res_data.get('msg')}")
            else:
                print("[-] Invalid response payload received.")
        except Exception as e:
            print(f"[-] Network Exception during termination: {e}")

    # ==========================================
    # Main Event Loop
    # ==========================================
    def start_daemon(self) -> None:
        """Main loop orchestrating the daemon execution."""
        self.logger.info("=========================================================")
        self.logger.info("             Dr.COM Auto-Authentication Daemon           ")
        self.logger.info("=========================================================")

        while True:
            try:
                current_ip = self.config["bind_interface_ip"] or self._get_physical_ip()
                
                # Egress Interface Validation
                if current_ip and current_ip != self.last_bind_ip:
                    self.logger.info(f"[Egress Binding] Hardware change detected. Binding traffic to -> {current_ip}")
                    self.session = self._create_bypassed_session(current_ip)
                    
                    primary_domain = self.config["campus_domains"][0]
                    if self.state.current_gateway != primary_domain:
                        self.state.current_gateway = primary_domain
                        self.logger.info(f"[Topology Reset] Restoring default gateway -> {self.state.current_gateway}")
                        
                    self.last_bind_ip = current_ip
                
                elif not current_ip and self.last_bind_ip is not None:
                    self.logger.info("[Egress Binding] Physical adapter offline. Releasing socket binds.")
                    self.session = self._create_bypassed_session()
                    self.last_bind_ip = None
                    
                if not current_ip:
                    if self.state.last_network_state != "NO_NETWORK":
                        self.logger.warning("[System] Network inaccessible (No Interface IP). Suspending background checks...")
                        self.state.last_network_state = "NO_NETWORK"
                    time.sleep(self.config["check_interval"])
                    continue

                if not self._check_campus_environment():
                    if self.state.last_network_state != "NOT_CAMPUS":
                        self.logger.info("[System] Host is currently outside the campus intranet. Suspending operations...")
                        self.state.last_network_state = "NOT_CAMPUS"
                    time.sleep(self.config["check_interval"])
                    continue

                net_status = self._check_captive_portal()
                
                if net_status != self.state.last_network_state:
                    if net_status == "INTERNET_OK":
                        self.logger.info(f"[System] Internet connectivity verified via {self.state.current_gateway}. Idling...")
                    elif net_status == "NEED_LOGIN":
                        self.logger.info(f"[System] Captive portal intercept detected on {self.state.current_gateway}. Initiating authentication...")
                    elif net_status == "NO_NETWORK":
                        self.logger.warning("[System] Uplink unreachable (Timeout). Waiting for network recovery...")
                    self.state.last_network_state = net_status

                # Authorization State Machine
                if net_status == "NEED_LOGIN":
                    
                    # Exponential Backoff Rate Limiter
                    if self.state.consecutive_failures >= 5:
                        # Cap max backoff at 120s. Formula: 30s, 60s, 90s, 120s...
                        wait_time = min(120, 30 * (self.state.consecutive_failures - 4))
                        self.logger.error(f"[Security] Rate limit exceeded ({self.state.consecutive_failures} failures). Cooldown for {wait_time}s before next attempt.")
                        time.sleep(wait_time)
                        # NOTE: Intentionally removed `continue` here to allow execution of _execute_authentication()
                        # This ensures the daemon auto-recovers gracefully once account balance is topped up.

                    auth_success = self._execute_authentication(current_ip)
                    
                    if auth_success:
                        self.logger.info("[System] Awaiting firewall policy propagation (6s)...")
                        time.sleep(6)
                        
                        post_status = self._check_captive_portal()
                        if post_status == "NEED_LOGIN":
                            self.logger.warning("[Anti-Spoofing] Server returned success, but upstream traffic remains blocked.")
                            self.logger.warning(f"[Diagnostics] Traversal fault. Gateway {self.state.current_gateway} mismatch with physical medium.")
                            
                            domains = self.config["campus_domains"]
                            current_idx = domains.index(self.state.current_gateway)
                            self.state.current_gateway = domains[(current_idx + 1) % len(domains)]
                            
                            self.logger.info(f"[Failover] Executing automatic failover to alternative gateway -> {self.state.current_gateway}")
                            self.state.consecutive_failures += 1
                            time.sleep(2) 
                            continue
                            
                        elif post_status == "INTERNET_OK":
                            self.logger.info("[System] Firewall policies verified. Connectivity fully restored.")
                            # Zero out the failure counter, full recovery
                            self.state.consecutive_failures = 0
                    else:
                        self.state.consecutive_failures += 1

                sleep_interval = self.config["check_interval"] + random.randint(0, 5) if net_status == "INTERNET_OK" else min(5, self.config["check_interval"])
                time.sleep(sleep_interval)

            except KeyboardInterrupt:
                self.logger.info("[System] Daemon terminated by user.")
                sys.exit(0)
            except Exception as e:
                self.logger.error(f"[System] Fatal exception in main event loop: {e}", exc_info=True)
                time.sleep(10)


if __name__ == "__main__":
    # Setup CLI Argument Parser
    parser = argparse.ArgumentParser(description="Dr.COM Authentication & Management Tool")
    parser.add_argument("-m", "--manage", action="store_true", help="Launch the Interactive Device Manager Console")
    args = parser.parse_args()

    try:
        daemon = DrComDaemon()
        if args.manage:
            daemon.launch_device_manager()
        else:
            daemon.start_daemon()
    except Exception as e:
        print(f"\n[!] Fatal Initialization Error: {e}")
        sys.exit(1)