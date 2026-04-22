"""
Microsoft Learn documentation lookup — dual-source enrichment via MCP.

Every answer is grounded in TWO knowledge sources:
  1. The AI model's own training knowledge (GPT-4o)
  2. Official Microsoft Learn documentation (via Microsoft Learn MCP Server)

This module connects to the Microsoft Learn MCP Server
(https://learn.microsoft.com/api/mcp) using the Model Context Protocol
to retrieve relevant documentation for BOTH the user's question AND any
errors/warnings found in the KQL query results. The combined context is
injected into the GPT-4o prompt so the model can cite official docs
alongside its own knowledge.

MCP endpoint: https://learn.microsoft.com/api/mcp
Authentication: None required (public, free).
Tools used: microsoft_docs_search
Reference: https://github.com/microsoftdocs/mcp
"""

import ast
import json
import re
import logging

import requests

logger = logging.getLogger(__name__)

_MCP_ENDPOINT = "https://learn.microsoft.com/api/mcp"
_REQUEST_TIMEOUT = 15  # seconds per MCP request
_MAX_SEARCH_TERMS = 3  # cap to avoid latency
_MAX_SNIPPETS = 5  # total snippets returned to the model


# ── MCP Protocol Helpers ────────────────────────────────────────────

def _parse_mcp_response(resp: requests.Response) -> dict:
    """Parse an MCP JSON-RPC response (JSON or Server-Sent Events)."""
    content_type = resp.headers.get("content-type", "")
    if "text/event-stream" in content_type:
        # SSE: find the last JSON-RPC data payload
        last_data = {}
        for line in resp.text.split("\n"):
            line = line.strip()
            if line.startswith("data:"):
                data_str = line[5:].strip()
                if data_str:
                    try:
                        last_data = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue
        return last_data
    try:
        return resp.json()
    except Exception:
        return {}


def _mcp_search(queries: list[str], top_per_query: int = 2) -> list[dict]:
    """
    Open ONE MCP session and call microsoft_docs_search for each query.
    Returns list of dicts: {title, url, description}.
    """
    results: list[dict] = []
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }

    try:
        session = requests.Session()

        # Step 1: MCP Initialize handshake
        init_resp = session.post(
            _MCP_ENDPOINT,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {
                        "name": "contoso-sql-log-analyzer",
                        "version": "1.0.0",
                    },
                },
            },
            headers=headers,
            timeout=_REQUEST_TIMEOUT,
        )
        init_resp.raise_for_status()

        session_id = init_resp.headers.get("mcp-session-id")
        if session_id:
            headers["Mcp-Session-Id"] = session_id

        # Step 2: Send initialized notification
        session.post(
            _MCP_ENDPOINT,
            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
            headers=headers,
            timeout=_REQUEST_TIMEOUT,
        )

        # Step 3: Call microsoft_docs_search for each query term
        for i, query in enumerate(queries):
            try:
                call_resp = session.post(
                    _MCP_ENDPOINT,
                    json={
                        "jsonrpc": "2.0",
                        "id": i + 10,
                        "method": "tools/call",
                        "params": {
                            "name": "microsoft_docs_search",
                            "arguments": {"query": query},
                        },
                    },
                    headers=headers,
                    timeout=_REQUEST_TIMEOUT,
                )
                call_resp.raise_for_status()
                data = _parse_mcp_response(call_resp)
                results.extend(_extract_docs(data, max_items=top_per_query))
            except Exception as e:
                logger.warning("MCP microsoft_docs_search failed for %r: %s", query, e)

        session.close()
    except Exception as e:
        logger.warning("MCP session to %s failed: %s", _MCP_ENDPOINT, e)

    return results


def _extract_docs(mcp_response: dict, max_items: int = 3) -> list[dict]:
    """Extract structured doc results from an MCP tools/call JSON-RPC response."""
    docs: list[dict] = []

    result = mcp_response.get("result", {})
    content_list = result.get("content", [])

    for content_item in content_list:
        if content_item.get("type") != "text":
            continue
        text = content_item.get("text", "")
        docs.extend(_parse_search_text(text, max_items))

    return docs[:max_items]


def _parse_search_text(text: str, max_items: int = 3) -> list[dict]:
    """
    Parse the text output from microsoft_docs_search into structured docs.
    Handles JSON, markdown link, and URL-based formats.
    """
    docs: list[dict] = []

    # Strategy 1: JSON response
    try:
        parsed = json.loads(text)
        items = []
        if isinstance(parsed, list):
            items = parsed
        elif isinstance(parsed, dict):
            items = (
                parsed.get("results", [])
                or parsed.get("items", [])
                or parsed.get("value", [])
            )
        for item in items[:max_items]:
            title = item.get("title", "")
            url = item.get("url", "") or item.get("link", "")
            desc = (
                item.get("description", "")
                or item.get("snippet", "")
                or item.get("summary", "")
            )
            if title and url:
                docs.append({"title": title, "url": url, "description": _clean_html(desc)})
        if docs:
            return docs
    except (json.JSONDecodeError, TypeError):
        pass

    # Strategy 2: Markdown links — [title](url)
    md_links = re.findall(
        r"\[([^\]]+)\]\((https?://learn\.microsoft\.com[^\)]+)\)", text
    )
    if md_links:
        for title, url in md_links[:max_items]:
            docs.append({"title": title.strip(), "url": url.strip(), "description": ""})
        return docs

    # Strategy 3: Bare URLs from learn.microsoft.com
    urls = re.findall(r"https?://learn\.microsoft\.com[^\s\)\]>\"]+", text)
    if urls:
        for url in urls[:max_items]:
            slug = url.rstrip("/").split("/")[-1]
            title = slug.replace("-", " ").title()
            docs.append({"title": title, "url": url, "description": ""})
        return docs

    # Strategy 4: Plain text is useful context — attach with any URL present
    if len(text) > 50:
        any_url = re.search(r"https?://[^\s\)\]>\"]+", text)
        if any_url:
            docs.append({
                "title": "Microsoft Learn Documentation",
                "url": any_url.group(),
                "description": text[:300].strip(),
            })

    return docs[:max_items]


def _clean_html(text: str) -> str:
    """Strip HTML tags from a snippet."""
    return re.sub(r"<[^>]+>", "", text).strip()


def extract_error_terms(log_results: str) -> list[str]:
    """
    Extract meaningful search terms from KQL result rows that contain errors.

    Strategies:
    1. Look for EventID numbers → search "SQL Server EventID {id}"
    2. Look for error source names → search "{Source} error"
    3. Look for short error phrases from RenderedDescription
    """
    terms: list[str] = []
    seen: set[str] = set()

    # Try to parse the result string back into a list of dicts
    rows = _parse_rows(log_results)
    if not rows:
        # Fallback: extract numbers that look like EventIDs and keywords
        event_ids = re.findall(r"'EventID':\s*(\d+)", log_results)
        for eid in event_ids[:2]:
            term = f"SQL Server EventID {eid}"
            if term not in seen:
                terms.append(term)
                seen.add(term)
        return terms[:_MAX_SEARCH_TERMS]

    for row in rows:
        level = str(row.get("EventLevelName", "")).lower()
        if level not in ("error", "warning"):
            continue

        # Strategy 1: EventID-based search
        event_id = row.get("EventID")
        source = row.get("Source", "")
        if event_id:
            term = f"SQL Server {source} EventID {event_id}".strip()
            if term not in seen:
                terms.append(term)
                seen.add(term)

        # Strategy 2: First meaningful sentence from RenderedDescription
        desc = str(row.get("RenderedDescription", ""))
        if desc and len(desc) > 20:
            # Take first sentence, cap at 120 chars for a focused search
            first_sentence = re.split(r"[.\n]", desc)[0][:120].strip()
            if first_sentence and first_sentence not in seen:
                term = f"SQL Server {first_sentence}"
                terms.append(term)
                seen.add(first_sentence)

        if len(terms) >= _MAX_SEARCH_TERMS:
            break

    return terms[:_MAX_SEARCH_TERMS]


def _parse_rows(log_results: str) -> list[dict]:
    """Safely parse the stringified list of dicts from KQL results."""
    try:
        parsed = ast.literal_eval(log_results)
        if isinstance(parsed, list):
            return parsed
    except (ValueError, SyntaxError):
        pass
    return []


def extract_question_terms(user_question: str) -> list[str]:
    """
    Build search terms from the user's natural language question.

    Focuses the search on SQL Server / Azure Monitor / Windows topics
    so results are relevant to the log-analysis context.
    """
    # Use the question itself, prefixed for specificity
    terms: list[str] = []

    # Primary: the user question scoped to SQL Server context
    cleaned = user_question.strip()[:150]
    terms.append(f"SQL Server {cleaned}")

    # Secondary: look for specific technical keywords to broaden coverage
    keywords = re.findall(
        r"(?:error|warning|event\s*id|login fail|timeout|deadlock|"
        r"backup|restore|performance|CPU|memory|disk|connection|replication)",
        user_question,
        re.IGNORECASE,
    )
    if keywords:
        kw_term = f"SQL Server {' '.join(dict.fromkeys(keywords))} troubleshoot"
        if kw_term != terms[0]:
            terms.append(kw_term)

    return terms[:2]  # max 2 question-based terms


def enrich_with_learn_docs(
    user_question: str,
    log_results: str = "",
) -> str:
    """
    Dual-source enrichment: search Microsoft Learn MCP Server using BOTH
    the user's question AND error terms extracted from KQL results.

    Knowledge sources for the final answer:
      1. AI Model knowledge (GPT-4o training data)
      2. Microsoft Learn documentation (this function, via MCP)

    Returns a formatted context block for injection into the GPT-4o prompt.
    Returns empty string only if all searches fail.
    """
    # Source A: terms from the user's question (always searched)
    question_terms = extract_question_terms(user_question)

    # Source B: terms from KQL error/warning rows (searched when available)
    error_terms = extract_error_terms(log_results) if log_results else []

    all_terms = question_terms + error_terms
    all_terms = list(dict.fromkeys(all_terms))  # dedupe, preserve order
    all_terms = all_terms[:_MAX_SEARCH_TERMS + 2]  # allow up to 5 searches

    if not all_terms:
        return ""

    # Search via MCP — single session, multiple tool calls
    all_snippets = _mcp_search(all_terms, top_per_query=2)

    if not all_snippets:
        return ""

    # Deduplicate by URL
    seen_urls: set[str] = set()
    unique: list[dict] = []
    for s in all_snippets:
        if s["url"] not in seen_urls:
            seen_urls.add(s["url"])
            unique.append(s)
    unique = unique[:_MAX_SNIPPETS]

    # Format for injection into the GPT-4o prompt
    lines = [
        "=== MICROSOFT LEARN DOCUMENTATION CONTEXT ===",
        "The following official Microsoft documentation is relevant to the "
        "user's question and/or the query results. You MUST reference these "
        "in your answer and include the URLs as clickable links so the "
        "engineer can read the full articles.\n",
    ]
    for i, doc in enumerate(unique, 1):
        lines.append(f"{i}. **{doc['title']}**")
        lines.append(f"   URL: {doc['url']}")
        if doc["description"]:
            lines.append(f"   Summary: {doc['description']}")
        lines.append("")

    return "\n".join(lines)
