# DecoAI Assistant

An agentic AI assistant for planning, visualizing, pricing, and managing event decorations using on-device, edge, and cloud AI.

DecoAI Assistant transforms a simple request such as:

> "Decorate my home for a birthday party."

into an actionable decoration plan.

Instead of requiring users to manually search for inspiration, determine what supplies they need, check inventory, estimate costs, and purchase missing materials, DecoAI connects these steps through a single intelligent assistant.

The system combines a Samsung Galaxy S25 mobile interface, Snapdragon X Elite AI PC, Arduino Uno Q edge device, cloud AI, generative models, vision-language models, voice AI, and an agentic orchestration layer to bridge digital event planning with physical decoration inventory.

## Motivation

Celebrating events at home is extremely common, but planning those events remains fragmented.

Consumers often need to move between inspiration platforms, shopping websites, messaging apps, decorators, and physical inventories just to determine what a setup will look like and how much it will cost.

The DecoAI presentation highlights a large and growing market around at-home celebrations and party supplies, including a projected global party-supplies market of more than $41 billion by 2034. It also highlights how many consumers make party-supply purchases shortly before their events, increasing the value of faster planning and purchasing workflows.

DecoAI addresses this problem by turning the planning process into a conversation with an AI assistant.

## What is DecoAI?

DecoAI is a multimodal, agentic event-decoration assistant.

A user can ask DecoAI to decorate a space for an event through their phone. The assistant can understand the request, generate potential decoration designs, determine what physical materials are required, inspect available warehouse inventory, estimate costs, and return decoration options to the user.

The system is designed around four major components:

### Phone — User Interface

The Samsung Galaxy S25 acts as the primary user-facing device.

Users communicate with DecoAI through a mobile/Telegram interface using text or voice.

The phone serves as the entry point into the system and displays generated decoration ideas, pricing information, and other results.

### Brain — AI Orchestration and Generation

A Snapdragon X Elite AI PC acts as the primary AI compute and orchestration system.

It coordinates:

- Agentic workflows
- User request processing
- Decoration image generation
- Vision-language understanding
- Inventory queries
- Cost estimation
- Cloud AI requests
- Communication with the edge vision system

The presentation describes this component as the "Brain" of DecoAI.

### Eyes — Edge Vision

An Arduino Uno Q provides DecoAI with a connection to the physical environment.

The edge device runs a vision-language model that can analyze images associated with the warehouse or physical decoration inventory.

This effectively gives the AI assistant "eyes" into the real world rather than restricting it to information stored digitally.

### Warehouse — Physical Inventory

The physical decoration warehouse represents the real-world resources available to DecoAI.

The system can connect AI-generated decoration concepts with actual inventory, helping determine:

1. What the design requires
2. What is already available
3. What is missing
4. What needs to be purchased
5. Estimated final cost

Together, these components create the full DecoAI workflow:

```
User
  |
  v
Samsung Galaxy S25
"Decorate my home..."
  |
  v
Snapdragon X Elite
AI Brain / Agent Orchestration
  |
  +---------------------+
  |                     |
  v                     v
Cloud AI          Generative AI
  |                     |
  +----------+----------+
             |
             v
       Arduino Uno Q
        Edge Vision
             |
             v
         Warehouse
             |
             v
  Inventory + Pricing
             |
             v
    Decoration Options
             |
             v
           User
```

This Phone → Brain → Eyes → Warehouse architecture is the central system concept shown in the project's presentation.

## Core Features

### Natural-Language Event Planning

Users interact with DecoAI conversationally rather than configuring individual AI tools.

For example:

> "Decorate my home for a blue and gold birthday party."

DecoAI interprets the request and coordinates the appropriate AI services.

### Voice Interaction

DecoAI supports voice-based interaction so users can communicate naturally with the assistant.

The voice pipeline incorporates Qualcomm Voice AI and Whisper as part of the mobile interaction stack. These technologies are explicitly included in the project's phone-side technology stack.

### Agentic AI Orchestration

OpenClaw serves as the agentic orchestration layer for DecoAI.

Rather than requiring the user to manually invoke individual services, OpenClaw coordinates specialized tools and AI models based on the user's request.

DecoAI includes workflows for:

- Inventory management
- Cost estimation
- Decoration generation
- Image analysis
- Amazon URL generation
- Model/service communication

OpenClaw is shown as part of the AI PC stack alongside the project's vision and image-generation models.

### AI Decoration Generation

DecoAI can transform natural-language descriptions into visual decoration concepts.

For example:

> "Create a sophisticated blue and gold birthday setup with a balloon arch, backdrop, flowers, and dessert table."

The system can generate multiple visual concepts and return them to the user for consideration.

The project uses multiple image-generation approaches across local and cloud infrastructure, including:

- Stable Diffusion 2.1
- Stable Diffusion XL Turbo

Stable Diffusion 2.1 is part of the Snapdragon X Elite/GenieX stack, while Stable Diffusion XL Turbo is shown as part of the cloud AI stack.

### Vision-Language Understanding

DecoAI uses vision-language models to understand decoration images.

The system can analyze a generated or captured image and reason about the objects needed to reproduce the decoration.

Examples include:

- Balloons
- Backdrop
- Flowers
- Tables
- Signs
- Lighting
- Decorative props
- Event accessories

The Snapdragon X Elite pipeline incorporates Qwen2.5-VL 7B Instruct, while the Uno Q edge vision system uses Qwen3.5-2B VL.

### Inventory-Aware Planning

Generating an attractive decoration is only part of the problem.

DecoAI connects generated concepts to the decorator's inventory.

Once the system determines what objects are required, it can compare those requirements against available inventory.

```
AI Generated Design
        |
        v
  Vision Analysis
        |
        v
Required Materials
        |
        v
 Inventory Lookup
       / \
      /   \
Available  Missing
             |
             v
      Purchase Options
```

This enables DecoAI to generate designs that can ultimately be translated into real-world decoration setups.

### Cost Estimation

DecoAI's cost-estimation workflow determines the approximate cost associated with creating a proposed setup.

The system can combine:

- Required materials
- Existing inventory
- Missing materials
- Item prices

to create an estimated total cost.

The resulting design and pricing information can then be returned to the user's phone.

### Product Search

When required items are not currently available, DecoAI can generate Amazon search URLs for missing materials.

This connects:

Idea → Design → Inventory → Missing Items → Purchase

into one continuous workflow.

### Edge AI Warehouse Vision

The Arduino Uno Q acts as DecoAI's edge intelligence layer.

It connects the AI system to physical warehouse information and runs Qwen3.5-2B VL for vision-language inference.

This architecture allows the system to combine centralized AI reasoning with smaller models deployed closer to the physical environment.

## Tech Stack

DecoAI intentionally distributes workloads across mobile, AI PC, cloud, and edge hardware rather than relying on a single compute environment.

### Hardware

| Hardware | Role |
|---|---|
| Samsung Galaxy S25 | User-facing mobile interface |
| Snapdragon X Elite AI PC | Primary AI compute and orchestration |
| Qualcomm NPU | Hardware-accelerated local AI inference |
| Arduino Uno Q | Edge AI and warehouse vision |
| ESP32-CAM | Physical image capture |
| Cloud AI Infrastructure | Large-model and additional generative AI workloads |

The presentation specifically shows the Samsung S25, X Elite, AI Box/cloud, and Uno Q as the major compute points in the system.

### AI Models

| Model | Purpose | Execution |
|---|---|---|
| Qwen2.5-VL 7B Instruct | Vision-language understanding | Snapdragon X Elite |
| Stable Diffusion 2.1 | Decoration image generation | Snapdragon X Elite |
| Llama 3.3 70B | Large-language-model reasoning | Cloud / Cirrascale |
| Stable Diffusion XL Turbo | Fast image generation | Cloud / Cirrascale |
| Qwen3.5-2B VL | Edge vision-language understanding | Arduino Uno Q |
| Whisper | Speech recognition | Voice/mobile pipeline |

The presentation identifies the local X Elite models as Qwen2.5-VL 7B Instruct and Stable Diffusion 2.1, the cloud stack as Llama 3.3 70B and Stable Diffusion XL Turbo, and the Uno Q model as Qwen3.5-2B VL.

### Qualcomm Technologies

The project incorporates several components of the Qualcomm AI ecosystem.

| Technology | Usage |
|---|---|
| Snapdragon X Elite | Main local AI compute platform |
| Qualcomm NPU | Accelerated local inference |
| Qualcomm AI Hub | AI model deployment ecosystem |
| GenieX | Local AI model execution |
| Qualcomm AI Runtime SDK (QAIRT) | AI runtime/deployment |
| Qualcomm Voice AI | Voice interaction |
| QNN | Qualcomm neural-network acceleration |

The project's Qualcomm stack is explicitly centered around Snapdragon, Qualcomm AI Hub/GenieX, Voice AI, and QAIRT.

### Agent and Backend

| Technology | Usage |
|---|---|
| OpenClaw | Agent orchestration |
| Python | AI pipelines and backend services |
| SQLite | Inventory and application data |
| Node.js | Mobile/Telegram bridge |
| PowerShell | Windows setup and automation |
| REST / Local Services | Communication between components |

### Mobile

| Technology | Usage |
|---|---|
| Android | Mobile application |
| Samsung Galaxy S25 | Demo mobile hardware |
| Telegram | Conversational interface |
| Whisper | Speech-to-text |
| Qualcomm Voice AI | Voice processing |
| ADB | Android deployment and debugging |

### Cloud

| Technology | Usage |
|---|---|
| Cirrascale | Cloud AI infrastructure |
| Llama 3.3 70B | Cloud LLM |
| Stable Diffusion XL Turbo | Cloud image generation |
| [TODO: ADD CLOUD API DETAILS] | [TODO] |

The presentation shows Cirrascale as the cloud/AI Box infrastructure associated with Llama 3.3 70B and Stable Diffusion XL Turbo.

## System Architecture

```
                           DECOAI ASSISTANT

                               User
                                |
                         Text / Voice Request
                                |
                                v
                    +-----------------------+
                    |   Samsung Galaxy S25  |
                    |  Android + Telegram   |
                    |  Voice AI + Whisper   |
                    +-----------+-----------+
                                |
                                v
                    +-----------------------+
                    | Snapdragon X Elite PC |
                    |                       |
                    |   OpenClaw Agent      |
                    |      "Brain"          |
                    +-----------+-----------+
                                |
              +-----------------+------------------+
              |                 |                  |
              v                 v                  v
       Qwen2.5-VL         Stable Diffusion     Cloud AI
       Vision Model             2.1                |
              |                 |           +------+------+
              |                 |           |             |
              |                 |      Llama 3.3      SDXL Turbo
              |                 |           70B
              |                 |
              +--------+--------+
                       |
                       v
                 Agent Workflow
                       |
              +--------+--------+
              |                 |
              v                 v
        Inventory / Cost    Arduino Uno Q
           Services          Edge "Eyes"
                                  |
                                  v
                           Qwen3.5-2B VL
                                  |
                                  v
                         Physical Warehouse
                                  |
                                  v
                          Inventory Context
                                  |
                                  v
                          Final Decoration
                         Plan + Cost + Items
                                  |
                                  v
                         Samsung Galaxy S25
```

## End-to-End Workflow

### 1. Ask

The user sends a request through their phone.

> "Decorate my home for a birthday party."

The presentation uses this exact type of interaction to illustrate the starting point of the DecoAI workflow.

### 2. Understand

The request is passed from the Samsung S25 to the Snapdragon X Elite AI system.

OpenClaw determines which tools and models should handle the request.

### 3. Generate

DecoAI generates possible visual decoration concepts using its image-generation pipeline.

### 4. Analyze

Vision-language models analyze the selected design to determine the materials required to recreate it.

### 5. Inspect

The edge vision system provides information about the physical decoration inventory.

### 6. Compare

DecoAI determines:

Required Items − Available Inventory = Missing Items

### 7. Price

The cost-estimation system determines the approximate cost of the setup.

### 8. Source

Missing materials can be mapped to purchasing options.

### 9. Respond

DecoAI sends the user:

- Decoration Concepts
- Required Materials
- Available Inventory
- Missing Items
- Estimated Cost
- Purchase Options

The result is a complete path from "Decorate my home" to an actionable physical event-decoration plan.

## Repository Structure

```
DecoAI_Assistant/
|
|-- Mobile_Telegram/
|   |-- app-debug.apk
|   |-- setup-node.ps1
|   `-- openclaw-whisper-node-bridge/
|
|-- Openclaw-setup/
|   |-- Skills/
|   |-- System/
|   |-- setup.ps1
|   |-- start.ps1
|   |-- DEPLOYMENT.md
|   `-- README.md
|
|-- UnoQ-ESP32-VLM/
|   |-- scripts/
|   `-- README.md
|
|-- stable-diffusion-local/
|   |-- generate.py
|   |-- session_server.py
|   |-- qnn_runner.py
|   |-- quantization.py
|   |-- scheduler.py
|   |-- tokenizer.py
|   `-- README.md
|
|-- cirrascale/
|
|-- final-submission/
|
|-- requirements.txt
`-- README.md
```

## Setup

### 1. Clone the Repository

```bash
git clone https://github.com/kmounika612-design/DecoAI_Assistant.git
cd DecoAI_Assistant
```

### 2. Requirements

- [TODO: ADD COMPLETE SOFTWARE REQUIREMENTS]
- [TODO: ADD PYTHON VERSION]
- [TODO: ADD NODE.JS VERSION]
- [TODO: ADD QUALCOMM SDK REQUIREMENTS]
- [TODO: ADD MODEL DOWNLOAD REQUIREMENTS]

### Android Setup

Install Android SDK Platform-Tools:
https://developer.android.com/tools/releases/platform-tools

Enable USB debugging on the Android device and verify:

```bash
adb devices
```

Install the DecoAI APK:

```bash
adb install Mobile_Telegram/app-debug.apk
```

For Windows:

```powershell
cd Mobile_Telegram
.\setup-node.ps1
```

- [TODO: ADD TELEGRAM CONFIGURATION]
- [TODO: ADD NETWORK CONFIGURATION]

### OpenClaw Setup

```powershell
cd Openclaw-setup
.\setup.ps1
.\start.ps1
```

- [TODO: ADD REQUIRED ENVIRONMENT VARIABLES]
- [TODO: ADD MODEL ENDPOINT CONFIGURATION]

### Local AI Setup

- [TODO: ADD SNAPDRAGON X ELITE / GENIEX SETUP]
- [TODO: ADD QWEN2.5-VL MODEL SETUP]
- [TODO: ADD STABLE DIFFUSION 2.1 SETUP]
- [TODO: ADD QAIRT / QNN CONFIGURATION]

### Cloud AI Setup

- [TODO: ADD CIRRASCALE CONFIGURATION]
- [TODO: ADD LLAMA 3.3 70B ENDPOINT]
- [TODO: ADD SDXL TURBO ENDPOINT]

### Uno Q Setup

```bash
cd UnoQ-ESP32-VLM
adb devices
```

- [TODO: ADD QWEN3.5-2B VL DEPLOYMENT]
- [TODO: ADD ESP32-CAM CONFIGURATION]
- [TODO: ADD WAREHOUSE CAMERA CONFIGURATION]

## Demo

### Demo Video

[TODO: ADD DEMO VIDEO]

### Hackathon Submission

[TODO: ADD SUBMISSION LINK]

### Screenshots

- [TODO: ADD MOBILE INTERFACE]
- [TODO: ADD DECORATION GENERATION]
- [TODO: ADD INVENTORY ANALYSIS]
- [TODO: ADD COST ESTIMATION]
- [TODO: ADD UNO Q / WAREHOUSE SETUP]

## Team

Team DecoAI

- Gayathri — [TODO: CONTRIBUTION]
- Mounika — [TODO: CONTRIBUTION]
- Pragnya — [TODO: CONTRIBUTION]
- Amisha — [TODO: CONTRIBUTION]
- Vivek — [TODO: CONTRIBUTION]

Team DecoAI's presentation shows the five-person team together in the final project slide.

## Future Work

DecoAI can be extended with:

- Real-time warehouse inventory detection
- Automatic inventory updates from camera feeds
- Improved material quantity estimation
- More advanced decoration generation
- Personalized decoration recommendations
- Budget-constrained design generation
- Automatic comparison of generated designs by price
- Direct retailer APIs
- Autonomous purchasing workflows
- Multi-user decorator dashboards
- Additional edge AI devices
- Expanded on-device inference
- End-to-end event planning beyond decorations

## License

[TODO: ADD LICENSE]

## Acknowledgments

Built by Team DecoAI.

DecoAI combines mobile, edge, local, and cloud AI to turn a simple event idea into a visual, inventory-aware, and cost-aware decoration plan.

GitHub: [kmounika612-design/DecoAI_Assistant](https://github.com/kmounika612-design/DecoAI_Assistant)

