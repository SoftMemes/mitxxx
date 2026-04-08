#!/usr/bin/env python3
"""
Analyze a mitmproxy flow file and dump a human-readable summary of HTTP traffic.
Useful for protocol reverse engineering.
"""
import json
import sys
import argparse
from urllib.parse import urlparse

try:
    from mitmproxy.io import FlowReader
    from mitmproxy.http import HTTPFlow
except ImportError:
    print("mitmproxy not installed. Run: pip install mitmproxy", file=sys.stderr)
    sys.exit(1)


def truncate(s, n=500):
    if len(s) > n:
        return s[:n] + f"... [{len(s) - n} more chars]"
    return s


def format_json_body(body_bytes):
    try:
        obj = json.loads(body_bytes)
        return json.dumps(obj, indent=2)
    except Exception:
        return body_bytes.decode("utf-8", errors="replace")


def analyze(flow_path, host_filter=None, json_only=False, show_cookies=False,
            show_bodies=False, export_endpoints=False):
    flows = []
    with open(flow_path, "rb") as f:
        reader = FlowReader(f)
        for flow in reader.stream():
            if isinstance(flow, HTTPFlow):
                flows.append(flow)

    if export_endpoints:
        endpoints = set()
        for flow in flows:
            parsed = urlparse(flow.request.pretty_url)
            if host_filter and host_filter not in parsed.netloc:
                continue
            endpoints.add(f"{flow.request.method} {parsed.netloc}{parsed.path}")
        for e in sorted(endpoints):
            print(e)
        return

    print(f"Total HTTP flows: {len(flows)}\n")

    # Group by host for overview
    by_host = {}
    for flow in flows:
        parsed = urlparse(flow.request.pretty_url)
        host = parsed.netloc
        if host not in by_host:
            by_host[host] = []
        by_host[host].append(flow)

    for host, host_flows in sorted(by_host.items()):
        if host_filter and host_filter not in host:
            continue
        print(f"{'='*60}")
        print(f"HOST: {host}  ({len(host_flows)} requests)")
        print(f"{'='*60}")
        for flow in host_flows:
            parsed = urlparse(flow.request.pretty_url)
            status = flow.response.status_code if flow.response else "?"
            ct = flow.response.headers.get("content-type", "") if flow.response else ""

            if json_only and "json" not in ct:
                continue

            print(f"\n  {flow.request.method} {parsed.path}{'?' + parsed.query if parsed.query else ''} [{status}]")
            if ct:
                print(f"  Content-Type: {ct}")

            if show_cookies:
                req_cookie = flow.request.headers.get("cookie", "")
                if req_cookie:
                    print(f"  -> Cookie: {truncate(req_cookie, 200)}")
                if flow.response:
                    for k, v in flow.response.headers.fields:
                        if k.lower() == b"set-cookie":
                            print(f"  <- Set-Cookie: {truncate(v.decode(), 120)}")

            if flow.response:
                location = flow.response.headers.get("location", "")
                if location:
                    print(f"  -> Location: {location[:150]}")

            if show_bodies and flow.response and flow.response.content:
                body = flow.response.content
                if "json" in ct:
                    formatted = format_json_body(body)
                    print(f"  Body:\n{truncate(formatted, 800)}")
                else:
                    decoded = body.decode("utf-8", errors="replace")
                    print(f"  Body: {truncate(decoded, 300)}")
        print()


def main():
    parser = argparse.ArgumentParser(description="Analyze a mitmproxy flow file")
    parser.add_argument("flow_file", help="Path to the .flow file")
    parser.add_argument("--host", dest="host_filter", default=None,
                        help="Filter to hosts containing this substring")
    parser.add_argument("--json-only", action="store_true",
                        help="Only show responses with JSON content-type")
    parser.add_argument("--show-cookies", action="store_true",
                        help="Include cookie headers in output")
    parser.add_argument("--show-bodies", action="store_true",
                        help="Include response bodies (truncated)")
    parser.add_argument("--export-endpoints", action="store_true",
                        help="Print unique sorted list of METHOD HOST/PATH and exit")
    args = parser.parse_args()

    analyze(
        args.flow_file,
        host_filter=args.host_filter,
        json_only=args.json_only,
        show_cookies=args.show_cookies,
        show_bodies=args.show_bodies,
        export_endpoints=args.export_endpoints,
    )


if __name__ == "__main__":
    main()
