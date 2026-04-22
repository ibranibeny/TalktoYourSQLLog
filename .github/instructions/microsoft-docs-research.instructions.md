---
applyTo: "**"
description: "Use when answering questions about Microsoft technologies like C#, F#, ASP.NET Core, Microsoft.Extensions, NuGet, Entity Framework, the dotnet runtime, Azure SDKs, or any native Microsoft platform API."
---
# Microsoft Documentation Research

When handling questions about native Microsoft technologies, use the MCP documentation tools to ground answers in the latest official sources.

## When to Use

Use the `microsoft_docs_search`, `microsoft_docs_fetch`, and `microsoft_code_sample_search` tools for **specific or narrowly defined** questions involving:

- C#, F#, VB.NET language features
- ASP.NET Core, Blazor, Minimal APIs
- Microsoft.Extensions (DI, Configuration, Logging, Hosting)
- Entity Framework / EF Core
- NuGet package authoring or consumption
- The `dotnet` CLI and runtime
- Azure SDK for .NET
- MSBuild, project files, target frameworks

## Workflow

1. **Search first** — call `microsoft_docs_search` with a focused query to find relevant docs.
2. **Fetch for depth** — if a search result looks relevant but the snippet is insufficient, call `microsoft_docs_fetch` with the URL to get the full page.
3. **Code samples** — call `microsoft_code_sample_search` when you need practical implementation examples; use the optional `language` filter (e.g., `csharp`).

## Guidelines

- Prefer official documentation over training-data recall for version-specific APIs, new features, or breaking changes.
- Cite the source URL when referencing a specific doc page.
- Do not call these tools for broad, well-known concepts that don't require up-to-date verification.
