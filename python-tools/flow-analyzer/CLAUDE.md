# flow-analyzer

Parses mitmproxy flow capture files and dumps a human-readable summary of HTTP traffic.

## Purpose

Used during protocol reverse engineering to understand what API calls the MITx app makes, what cookies/headers are sent, and what responses look like. Feed it any `.flow` file captured with mitmproxy.

## Usage

```bash
python analyze.py <path-to-flow-file> [options]

Options:
  --host PATTERN      filter to hosts matching this substring
  --json-only         only show responses with JSON content-type
  --show-cookies      include full cookie headers in output
  --show-bodies       include response bodies (truncated)
  --export-endpoints  print a unique sorted list of METHOD HOST/PATH
```

## Examples

```bash
# Overview of all traffic
python analyze.py ../../captures/mitx-login-discover-courses-download-video.flow

# Just the API calls to the two main hosts
python analyze.py ../../captures/mitx-login-discover-courses-download-video.flow --json-only

# Show what cookies the login flow sets
python analyze.py ../../captures/mitx-login-discover-courses-download-video.flow --host sso.ol.mit.edu --show-cookies

# Dump all unique endpoint patterns
python analyze.py ../../captures/mitx-login-discover-courses-download-video.flow --export-endpoints
```
