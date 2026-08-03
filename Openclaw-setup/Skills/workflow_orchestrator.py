#!/usr/bin/env python3
"""
Decoration Concept Workflow Orchestrator

Automates the flow: Image analysis → Cost estimation → Telegram notification to owner

Usage:
    python workflow_orchestrator.py <image-path> [--output-file <path>]

This script:
1. Analyzes the decoration image to detect items and check stock
2. Automatically invokes cost estimation for missing items
3. Formats and returns the complete cost breakdown
4. Sends missing items list to owner via Telegram bot
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

try:
    import requests
except ImportError:
    requests = None


def run_geniex_inference(image_path: str) -> dict:
    """Call Geniex server to detect items in image using Qwen2.5-VL model."""
    if not requests:
        print("Warning: requests library not installed, skipping Geniex inference")
        return {"items": [], "raw_response": "requests not available"}

    try:
        # Geniex server runs on localhost:18181 by default
        url = "http://127.0.0.1:18181/v1/chat/completions"

        with open(image_path, "rb") as f:
            image_data = f.read()

        # Prepare request for Geniex server (OpenAI-compatible API)
        payload = {
            "model": "Qwen2.5-VL-7B-Instruct",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": "Analyze this decoration image and list all decoration items you can see. Return a JSON array with items like: [{\"item_name\": \"...\", \"color\": \"...\", \"quantity\": ...}]"
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{__import__('base64').b64encode(image_data).decode()}"
                            }
                        }
                    ]
                }
            ]
        }

        response = requests.post(url, json=payload, timeout=60)

        if response.status_code == 200:
            result = response.json()
            # Extract items from response
            if result.get("choices") and len(result["choices"]) > 0:
                content = result["choices"][0].get("message", {}).get("content", "")
                try:
                    # Try to parse JSON from response
                    import re
                    json_match = re.search(r'\[.*\]', content, re.DOTALL)
                    if json_match:
                        items = json.loads(json_match.group())
                        return {"items": items, "raw_response": content}
                except:
                    pass
            return {"items": [], "raw_response": result}
        else:
            print(f"Warning: Geniex returned {response.status_code}: {response.text}")
            return {"items": [], "raw_response": f"Geniex error: {response.status_code}"}
    except Exception as e:
        print(f"Warning: Geniex inference failed: {e}")
        return {"items": [], "raw_response": str(e)}


def run_image_analysis(image_path: str) -> dict:
    """Analyze decoration image and detect items."""
    # First try Geniex service for real item detection
    print("Calling Geniex service for item detection...")
    geniex_result = run_geniex_inference(image_path)

    if geniex_result.get("items"):
        print(f"✓ Geniex detected {len(geniex_result['items'])} items")
        return geniex_result

    # Fallback to inventory-management CLI (uses mock data if no model configured)
    print("Geniex unavailable or no items detected, using fallback analysis...")
    cmd = [
        "python",
        ".\skills\inventory-management\cli\image_cli.py",
        image_path,
        "--json"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Image analysis failed: {result.stderr}")
    return json.loads(result.stdout)


def run_cost_estimation(missing_items: list) -> dict:
    """Get cost estimate for missing items."""
    if not missing_items:
        return {
            "lines": [],
            "total_cost": 0.0,
            "missing_items": []
        }

    items_json = json.dumps(missing_items)
    cmd = [
        "python",
        ".\skills\cost-estimation\cli\estimate_cli.py",
        items_json,
        "--json"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Cost estimation failed: {result.stderr}")
    return json.loads(result.stdout)


def send_telegram_notification(missing_items: list, total_cost: float) -> bool:
    """Send missing items list to owner via Telegram bot."""
    if not requests:
        print("Warning: requests library not installed, skipping Telegram notification")
        return False

    bot_token = os.getenv("TELEGRAM_BOT_TOKEN")
    chat_id = os.getenv("TELEGRAM_OWNER_CHAT_ID")

    if not bot_token or not chat_id:
        print("Warning: TELEGRAM_BOT_TOKEN or TELEGRAM_OWNER_CHAT_ID not set, skipping notification")
        return False

    if not missing_items:
        print("No missing items to notify owner about")
        return True

    # Format message
    lines = ["🛒 **Missing Items to Purchase**\n"]
    for item in missing_items:
        item_name = item.get("item_name", "Unknown")
        color = item.get("color")
        quantity = item.get("quantity", 1)
        full_name = f"{color} {item_name}" if color else item_name
        lines.append(f"• {full_name} x{quantity}")

    lines.append(f"\n💰 **Total Cost:** ${total_cost:.2f}")
    message = "\n".join(lines)

    # Send via Telegram
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": message,
        "parse_mode": "Markdown"
    }

    try:
        response = requests.post(url, json=payload, timeout=10)
        if response.status_code == 200:
            print(f"✓ Telegram notification sent to owner (chat_id: {chat_id})")
            return True
        else:
            print(f"Warning: Telegram API returned {response.status_code}: {response.text}")
            return False
    except Exception as e:
        print(f"Warning: Failed to send Telegram notification: {e}")
        return False


def format_results(image_analysis: dict, cost_estimate: dict) -> str:
    """Format results as a readable message for the owner."""
    lines = []

    # Header
    lines.append("=" * 70)
    lines.append("DECORATION CONCEPT COST ESTIMATE")
    lines.append("=" * 70)
    lines.append("")

    # Image analysis summary
    items_detected = len(image_analysis.get("results", []))
    present = len(image_analysis.get("present", []))
    partial = len(image_analysis.get("partial", []))
    missing = len(image_analysis.get("missing", []))

    lines.append(f"Items Detected: {items_detected}")
    lines.append(f"  ✓ In Stock: {present}")
    lines.append(f"  ⚠ Partial Stock: {partial}")
    lines.append(f"  ✗ Missing: {missing}")
    lines.append("")

    # Cost breakdown
    lines.append("COST BREAKDOWN")
    lines.append("-" * 70)

    for line in cost_estimate.get("lines", []):
        item_name = line.get("item_name", "Unknown")
        color = line.get("color")
        needed = line.get("needed", 0)
        in_stock = line.get("in_stock", 0)
        missing_qty = line.get("missing", 0)
        cost_ea = line.get("cost_ea", 0)
        line_cost = line.get("line_cost", 0)
        source = line.get("price_source", "unknown")

        # Format item name
        full_name = f"{color} {item_name}" if color else item_name

        # Format line
        if missing_qty > 0:
            lines.append(f"{full_name}")
            lines.append(f"  Needed: {needed} | In Stock: {in_stock} | To Buy: {missing_qty}")
            lines.append(f"  Unit Price: ${cost_ea:.2f} | Line Cost: ${line_cost:.2f} ({source})")
        else:
            lines.append(f"{full_name}")
            lines.append(f"  Needed: {needed} | In Stock: {in_stock} | ✓ Fully Covered")
        lines.append("")

    # Total cost
    total_cost = cost_estimate.get("total_cost", 0)
    lines.append("-" * 70)
    lines.append(f"TOTAL COST (DB-priced items only): ${total_cost:.2f}")
    lines.append("")

    # Missing items to purchase
    missing_items = cost_estimate.get("missing_items", [])
    if missing_items:
        lines.append("ITEMS TO PURCHASE")
        lines.append("-" * 70)
        for item in missing_items:
            item_name = item.get("item_name", "Unknown")
            color = item.get("color")
            quantity = item.get("quantity", 1)
            full_name = f"{color} {item_name}" if color else item_name
            lines.append(f"  • {full_name} x{quantity}")
        lines.append("")
        lines.append("Ready to generate Amazon links for these items? (Use amazon-url-builder skill)")
    else:
        lines.append("✓ All items are in stock! No purchases needed.")

    lines.append("=" * 70)

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: python workflow_orchestrator.py <image-path> [--output-file <path>]")
        sys.exit(1)

    image_path = sys.argv[1]
    output_file = None

    if "--output-file" in sys.argv:
        idx = sys.argv.index("--output-file")
        if idx + 1 < len(sys.argv):
            output_file = sys.argv[idx + 1]

    try:
        # Step 1: Analyze image
        print("Analyzing decoration image...")
        image_analysis = run_image_analysis(image_path)

        # Step 2: Get cost estimate
        print("Getting cost estimate...")
        missing_items = image_analysis.get("missing_items", [])
        cost_estimate = run_cost_estimation(missing_items)

        # Step 3: Format results
        print("Formatting results...")
        formatted = format_results(image_analysis, cost_estimate)

        # Output
        print(formatted)

        if output_file:
            Path(output_file).write_text(formatted)
            print(f"\nResults saved to: {output_file}")

        # Step 4: Send Telegram notification to owner
        total_cost = cost_estimate.get("total_cost", 0)
        send_telegram_notification(missing_items, total_cost)

        # Return JSON for programmatic use
        result = {
            "image_analysis": image_analysis,
            "cost_estimate": cost_estimate,
            "formatted_message": formatted
        }
        print("\n" + json.dumps(result, indent=2))

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
