---
title: Agent-first architecture
mode: explanation
---

# Agent-first architecture

Why ar-crawl keeps the AI in your agent and out of the crawler, and what that buys.

**AR-Crawl is designed for LLM agents to use as a reliable web crawling tool.**

## Design Philosophy: Separation of Concerns

Unlike tools that embed AI capabilities into the crawler itself, AR-Crawl follows a **separation of concerns** approach:

- **AR-Crawl's job**: Reliably crawl websites and provide clean, structured data
- **Your LLM agent's job**: Process the data using its intelligence

This architecture provides:
- ✅ **LLM-agnostic**: Works with any LLM (Claude, GPT, Llama, local models, etc.)
- ✅ **Maximum flexibility**: Agents can process data for any purpose
- ✅ **No vendor lock-in**: No dependency on specific AI services
- ✅ **Cost-effective**: No LLM API costs for crawling; agents process data separately
- ✅ **Clean separation**: Crawling logic is independent of AI processing logic

## Example: LLM Agent Workflow

```
┌──────────────┐
│  LLM Agent   │  (Claude Code, GPT Agent, etc.)
│  e.g. Claude │
│    Code      │
└──────┬───────┘
       │ 1. Invokes ar-crawl CLI
       ▼
┌──────────────┐
│  ar-crawl    │  Returns JSON/SQLite/CSV
└──────┬───────┘
       │ 2. Agent receives structured data
       ▼
┌──────────────┐
│  LLM Agent   │  3. Agent analyzes/processes data
│  Processing  │     using its own LLM capabilities
└──────────────┘
```

**Example Agent Task:**
```bash
User: "Analyze sentiment in recent tech news"

Agent workflow:
1. Agent invokes: ar-crawl crawl-site https://technews.com --output news.db --format sqlite
2. Agent queries SQLite DB for article text
3. Agent uses its LLM to analyze sentiment for each article
4. Agent presents findings to user
```

**Key Point**: The LLM agent uses AR-Crawl as a tool to get data, then applies its own intelligence. The AI is in the agent, not in AR-Crawl.

## Why Agent-First Architecture Matters

**Compared to AI-integrated tools** (like those with built-in LLM extraction):
- ✅ **No LLM vendor lock-in** - Use any AI model (Claude, GPT, Llama, local models)
- ✅ **Lower costs** - No LLM API charges for crawling; process data when/how you want
- ✅ **Maximum flexibility** - Same crawl data can be used for multiple AI tasks
- ✅ **Simpler architecture** - Pure crawling tool that does one thing well
- ✅ **Future-proof** - Switch LLMs without changing your crawling infrastructure
