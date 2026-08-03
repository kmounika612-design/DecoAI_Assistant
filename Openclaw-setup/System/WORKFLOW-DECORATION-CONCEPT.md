# Decoration Concept Workflow

Automated workflow: Client uploads decoration image → Detect items → Cost estimate → Send to owner

## Flow

1. **Client uploads image** (via OpenClaw chat/Telegram)
   - Image analyzed with `decoai-image` to detect decoration items
   - Returns: items detected, stock status (present/partial/missing), missing_items list

2. **Client confirms decor idea** (says "yes, let's do this" or similar)
   - Trigger cost estimation automatically
   - Use detected items as input to `decoai-estimate`
   - Returns: itemized estimate (have vs. need), total cost, missing_items list

3. **Send results to owner**
   - Cost breakdown (what's in stock, what needs to be bought, unit prices)
   - Missing items list (ready for Amazon URL Builder)
   - Recommendation: "Buy these X items for $Y total"

## Implementation

### Step 1: Image Analysis (Geniex + Fallback)
```bash
# Calls Geniex server (Qwen2.5-VL-7B-Instruct) if available on port 18181
# Falls back to inventory-management CLI if Geniex unavailable
python ".\skills\workflow_orchestrator.py" "<image-path>"
```
Output: `{items_detected, present, partial, missing, missing_items}`

**Note:** Geniex server is started automatically by `start.ps1` on port 18181

### Step 2: Cost Estimation (Triggered on Confirmation)
```bash
python ".\skills\cost-estimation\cli\estimate_cli.py" '<missing_items_json>' --json
```
Input: `missing_items` from Step 1
Output: `{lines, total_cost, missing_items}`

## Step 3: Send to Owner (via Telegram)
- Automatically sends missing items list to owner's Telegram bot
- Includes item names, quantities, and total cost
- Owner can then use Amazon URL Builder to generate purchase links

## Agent Instructions

When a client uploads a decoration image and confirms the idea:

1. **Analyze the image:**
   ```
   exec: python ".\skills\inventory-management\cli\image_cli.py" "<image-path>" --json
   ```
   Save the output (especially `missing_items`)

2. **Get cost estimate:**
   ```
   exec: python ".\skills\cost-estimation\cli\estimate_cli.py" '<missing_items_json>' --json
   ```
   This gives you the total cost and itemized breakdown

3. **Send results to client:**
   - "Here's the cost estimate for the decoration concept:"
   - Show itemized breakdown (items in stock vs. need to buy)
   - Show total cost

4. **Notify owner (automatic):**
   - The workflow automatically sends the missing items list to the owner's Telegram bot
   - Owner receives: item names, quantities, and total cost
   - Owner can then generate Amazon links for purchasing

## Example Workflow

**Client:** "I uploaded a photo of my dream decoration setup"
**Agent:** [Analyzes image, detects items]
**Agent:** "I found 8 decoration items in your photo. 3 are in stock, 5 need to be purchased."

**Client:** "Great! What will it cost?"
**Agent:** [Triggers cost estimation automatically]
**Agent:** "Here's the cost breakdown:
- Gold Balloons (20 units): $9.00 (in stock)
- Fairy Lights (3 units): $26.97 (need to buy)
- Paper Lanterns (6 units): $7.20 (need to buy)
- Silk Roses (20 units): $15.00 (in stock)
- Table Runners (2 units): $11.00 (need to buy)

**Total cost to complete: $60.17**

*[Owner receives Telegram notification with missing items list and total cost]*

**Owner:** [Receives Telegram message]
"🛒 Missing Items to Purchase
• Fairy Lights x3
• Paper Lanterns x6
• Table Runners x2

💰 Total Cost: $60.17"

**Owner:** [Uses Amazon URL Builder to generate purchase links]

## Integration Points

- **Inventory Management**: Provides item detection and stock status
- **Cost Estimation**: Provides pricing for missing items
- **Amazon URL Builder**: Generates purchase links for missing items
- **Telegram/Chat**: Delivers results to client and owner
