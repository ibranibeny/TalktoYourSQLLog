import os
import re
import streamlit as st
from azure.identity import DefaultAzureCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus
from openai import AzureOpenAI
from datetime import timedelta

from kql_prompt import build_system_prompt
from learn_search import enrich_with_learn_docs

# ── Configuration ───────────────────────────────────────────────────
WORKSPACE_ID = os.environ["LOG_ANALYTICS_WORKSPACE_ID"]
AOAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"]
AOAI_DEPLOYMENT = os.environ["AZURE_OPENAI_DEPLOYMENT"]

credential = DefaultAzureCredential()
logs_client = LogsQueryClient(credential)
aoai_client = AzureOpenAI(
    azure_endpoint=AOAI_ENDPOINT,
    azure_ad_token_provider=lambda: credential.get_token(
        "https://cognitiveservices.azure.com/.default"
    ).token,
    api_version="2024-06-01",
)

SYSTEM_PROMPT = build_system_prompt()


def extract_kql(text: str) -> str | None:
    """Extract the first KQL code block from the model's response."""
    match = re.search(r"```kql\s*(.*?)\s*```", text, re.DOTALL)
    return match.group(1).strip() if match else None


def execute_kql(kql: str) -> tuple[str, bool]:
    """
    Execute a KQL query against Log Analytics.
    Returns (result_text, success).
    Uses a 30-day timespan safety net; the KQL itself has the precise filter.
    """
    try:
        response = logs_client.query_workspace(
            workspace_id=WORKSPACE_ID,
            query=kql,
            timespan=timedelta(days=30),
        )
        if response.status == LogsQueryStatus.SUCCESS and response.tables:
            columns = [
                col.name if hasattr(col, "name") else str(col)
                for col in response.tables[0].columns
            ]
            rows = [dict(zip(columns, row)) for row in response.tables[0].rows]
            if not rows:
                return "Query executed successfully but returned 0 rows.", True
            return str(rows[:50]), True
        elif response.status == LogsQueryStatus.PARTIAL:
            return f"Partial results (query may have timed out): {response.partial_error}", False
        else:
            return "Query returned no tables.", True
    except Exception as e:
        return f"KQL execution error: {e}", False


# ── Streamlit UI ────────────────────────────────────────────────────
st.set_page_config(page_title="Contoso SQL Log Assistant", page_icon="\U0001f4ca")
st.title("Talk to Your SQL Logs")
st.caption("Powered by Azure AI Foundry \u00b7 Log Analytics \u00b7 Azure Monitor Agent")
st.markdown(
    "_Ask questions like: 'Why did errors spike on 12 April 2026?' "
    "or 'Show me the latest logs at 12:00pm 20 April 2026'_"
)

if "messages" not in st.session_state:
    st.session_state.messages = []

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

if prompt := st.chat_input("Ask about your SQL Server logs..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Generating KQL query..."):
            # ── Phase 1: NL → KQL translation ──────────────────────
            kql_response = aoai_client.chat.completions.create(
                model=AOAI_DEPLOYMENT,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
                temperature=0.0,  # deterministic KQL generation
            )
            kql_text = kql_response.choices[0].message.content
            kql_query = extract_kql(kql_text)

        if not kql_query:
            answer = (
                "I wasn't able to generate a KQL query for that question. "
                "Could you rephrase? For example:\n"
                "- *'Show me SQL errors from 12 April 2026'*\n"
                "- *'What was CPU usage in the last 6 hours?'*"
            )
            st.markdown(answer)
            st.session_state.messages.append({"role": "assistant", "content": answer})
        else:
            # Show the generated KQL
            st.markdown("**Generated KQL:**")
            st.code(kql_query, language="kql")

            with st.spinner("Executing query against Log Analytics..."):
                # ── Phase 2: Execute KQL ───────────────────────────
                log_results, success = execute_kql(kql_query)

            if not success:
                st.warning(f"Query issue: {log_results}")

            # ── Phase 2.5: Microsoft Learn enrichment (ALWAYS) ──
            with st.spinner("Searching Microsoft Learn docs..."):
                learn_context = enrich_with_learn_docs(
                    user_question=prompt,
                    log_results=log_results if success else "",
                )
                if learn_context:
                    st.markdown("✅ **Found relevant Microsoft Learn articles**")

            with st.spinner("Analysing results..."):
                # ── Phase 3: Dual-source answer (AI + MS Learn) ──
                results_content = (
                    f"Here are the query results:\n\n{log_results}\n\n"
                )
                if learn_context:
                    results_content += (
                        f"\n\n{learn_context}\n\n"
                    )
                results_content += (
                    "Your answer MUST combine TWO knowledge sources:\n"
                    "1. YOUR OWN KNOWLEDGE — Use your training data to "
                    "explain concepts, root causes, and best practices.\n"
                    "2. MICROSOFT LEARN DOCS — Reference the documentation "
                    "above with clickable URLs to back up your explanation.\n\n"
                    "For every key point, cite the relevant MS Learn article. "
                    "If there are errors, explain what each error means, "
                    "suggest root causes, and recommend resolution steps "
                    "grounded in both your knowledge and official documentation."
                )

                summary_response = aoai_client.chat.completions.create(
                    model=AOAI_DEPLOYMENT,
                    messages=[
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": prompt},
                        {"role": "assistant", "content": kql_text},
                        {"role": "user", "content": results_content},
                    ],
                    temperature=0.3,
                )
                answer = summary_response.choices[0].message.content

            st.markdown("---")
            st.markdown(answer)
            st.session_state.messages.append(
                {"role": "assistant", "content": f"**KQL:**\n```kql\n{kql_query}\n```\n\n{answer}"}
            )
