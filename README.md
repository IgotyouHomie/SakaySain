# SakaySain

## **TLDR Of Timeline**

---

## **Version 1 — Prototype Tracking System**

SakaySain V1 demonstrates the core concept of crowdsourced jeepney tracking.  
Users can place a **road waiting pin** and select the **direction** where incoming jeepneys are expected.

The system detects passengers moving at vehicle speed and treats them as **moving jeep sensors**.  
The nearest approaching jeep is identified and an **estimated arrival time (ETA)** is calculated.

This version focuses on validating the feasibility of using **passenger movement data** to estimate jeep arrivals.

---

## **Version 2 — Predictive Transport Intelligence**

SakaySain V2 expands the prototype into a **predictive transport intelligence system**.

This version introduces a **road graph architecture** where each road segment collects jeep movement statistics such as:

- travel time
- arrival intervals
- jeep flow rates

When passenger tracking ends, the system generates **ghost jeep predictions** that continue along the road graph based on historical data. This allows SakaySain to maintain jeep predictions even when no passengers are actively using the app.

Road segments become **interactive nodes** that store jeep statistics and visualize traffic flow using a **real-time chunk heatmap**.

The system also uses an **event-driven architecture** to improve scalability and performance.

## **Version 3 — Prediction Stability & Accuracy Framework**
TLDR

SakaySain V3 introduces an algorithm testing framework designed to improve ETA prediction stability and long-term accuracy.
The system evaluates predictions using multiple accuracy metrics while preventing ETA values from fluctuating excessively as new jeep data appears.
Chunk intelligence now learns from past prediction performance, allowing the system to automatically adjust prediction weights over time.

















## **Expanded Context of Added Features**

## V1 — Basic Jeep Tracking Prototype

(first repository push)

Core Goal

Demonstrate the basic concept of tracking incoming jeepneys using user movement data.

Main Features

• Users can place a Road Waiting Pin on a road
• User selects which direction jeeps should come from
• System detects moving users acting as jeep passengers
• Nearest approaching jeep is identified
• System computes basic ETA using distance and speed

Core Algorithms

• Speed detection (walking vs vehicle)
• Direction filtering (toward pin)
• Nearest jeep detection
• Basic ETA calculation

Example logic:

ETA = distance / speed
Purpose of V1

To validate the core crowdsourced tracking idea.

## V2 — Predictive Jeep Intelligence System

Core Goal

Transform SakaySain from simple tracking into a predictive transport system.

This version introduces road intelligence and probabilistic prediction.

V2 Main System Improvements
1. Observed Jeep Data

Real passenger users generate observed jeep movement data.

Chunks record:

• jeep pass events
• jeep types
• travel times
• arrival intervals

Each road segment becomes a data collection node.

2. Ghost Jeep Prediction System

When a passenger leaves a jeep and closes the app, the jeep would normally disappear.

Instead, the system converts it into a Ghost Jeep.

Ghost Jeeps:

• continue moving along the road graph
• use historical chunk speeds
• slowly lose confidence over time

This allows the system to continue tracking likely jeep positions even without passengers.

3. Road Segment Intelligence (Chunk System)

Roads are divided into segments called chunks.

Each chunk stores:

• average travel time
• jeep arrival intervals
• jeep flow rate
• jeep type statistics
• last jeep pass timestamp

Chunks act as local traffic knowledge units.

4. Multi-Road Intersection Graph

The road network is represented as a graph structure.

Nodes = intersections
Edges = road chunks

Each node may have multiple outgoing paths, allowing:

• realistic route branching
• ghost jeep route prediction
• flow analysis

This allows ghost jeeps to choose actual route branches instead of fixed paths.

5. Chunk Flow Rate Visualization

Road chunks now compute jeep flow rate:

flowRate = jeeps / time

Chunks are colored dynamically:

Low flow → light color
High flow → strong color

This creates a real-time jeep movement heatmap.

6. Interactive Chunk Statistics

Chunks are now interactive.

When a chunk is tapped, the system shows:

• average arrival interval (all jeep types)
• average arrival interval by jeep type
• jeep types that passed the segment
• last jeep pass time
• last jeep pass by jeep type

This allows deeper transport analytics and debugging.

7. Event-Based Road Intelligence System

Instead of constant recalculations, the system uses events.

Example events:

JEEP_ENTER_CHUNK
JEEP_EXIT_CHUNK
PASSENGER_BECAME_JEEP
PASSENGER_DISCONNECTED
GHOST_JEEP_CREATED

Chunks update only when events occur, making the system scalable.





## v3 – Prediction Stability & Accuracy Framework

Added Features
ETA Stability System

Navigation systems often suffer from rapid ETA fluctuations when new vehicle data appears.

V3 introduces an ETA stability mechanism that smooths predictions using weighted averaging.
This prevents sudden jumps in predicted arrival times and produces more realistic estimates.

Example stabilization:

Old ETA: 60s
New ETA: 30s
Smoothed ETA: 51s

This makes predictions gradually adjust rather than instantly jump.

Multi-Metric Accuracy Evaluation

Previous versions evaluated predictions using a simple accuracy formula.
V3 introduces additional evaluation metrics for better algorithm diagnostics.

Metrics include:

• Absolute Error
• Mean Absolute Error (MAE)
• Mean Absolute Percentage Error (MAPE)
• Relative Error
• Accuracy Score (0–100%)

Using multiple metrics prevents misleading results when wait times vary significantly.

Prediction Timing Validation

Prediction accuracy is now evaluated based on remaining wait time at the moment of prediction, rather than comparing predictions to total wait time.

This produces fairer and more meaningful accuracy measurements.

Self-Improving Chunk Confidence Weights

Road segments (chunks) now track prediction performance over time.

Each chunk stores:

average ETA accuracy

prediction error

jeep flow reliability

These statistics influence the hybrid ETA algorithm by dynamically adjusting prediction weights.

Example:

Chunk A accuracy: 85%
Chunk B accuracy: 62%

Chunks with higher reliability receive stronger weighting during prediction calculations.

This allows SakaySain to gradually learn which parts of the road network produce better predictions.

Prediction Diagnostics Panel (Dev Mode)

The testing interface now displays extended prediction diagnostics.

Example output:

Initial ETA: 72s
Actual Wait: 60.2s
Initial Accuracy: 83%

Final ETA: 3.2s
Actual Remaining: 5.0s
Final Accuracy: 64%

Prediction Source: Ghost Jeep
Confidence: Medium

Chunk Flow: 5.25 jeeps/min
Traffic Factor: 1.19

This allows developers to analyze prediction behavior and identify weaknesses in the algorithm.

Hybrid Prediction Improvements

The ETA system now combines multiple prediction signals:

Real passenger jeep tracking

Ghost jeep continuation

Statistical jeep flow

Predictions are blended using weighted averages to produce more stable arrival estimates.


## **SakaySain Development Roadmap (V4–V10) — TLDR**

## Version 4 — Road Network Editor & Local Activity Insights
Introduces a developer road network editor that allows manual creation of jeepney routes directly on the map. This enables accurate modeling of real-world jeepney paths and intersections. The version also adds local activity insights showing recent app usage and jeep types observed in an area.

## Version 5 — Community Verification & Voting System
Adds a crowdsourced verification system where users can vote on jeep sightings and route accuracy. Passenger and pedestrian votes are weighted differently, and a trust system helps improve reliability of the collected data. Establish proper UI for users (Make it Simple and Easy to learn but presentable modern UI). 

## Version 6 — Autonomous Prediction & Historical Modeling
Enhances the prediction system by using historical jeep movement patterns and time-based flow data to estimate arrivals even when no users are actively tracking jeeps. Includes CSV/JSON export for offline analysis of prediction performance.

## Version 7 — Multi-User Networking & Device Synchronization
Introduces real-device connectivity and real-time synchronization between users. Multiple users can appear on the map simultaneously, enabling live tracking and shared jeep observations across devices.

## Version 8 — Controlled Real-World Testing
Begins structured real-world testing using a small group of users and actual jeepney routes to evaluate prediction accuracy, reliability, and system behavior under real conditions.

## Version 9 — Public Beta & Crowd Stress Testing
Expands testing to a larger public audience. This stage focuses on gathering large-scale user data, validating prediction models, and stress-testing the system under higher usage.

## Version 10 — Final Stress Testing & System Evaluation
Performs final scalability tests and evaluates system performance, prediction accuracy, and reliability. This stage concludes the development roadmap with a full analysis of SakaySain’s effectiveness.
