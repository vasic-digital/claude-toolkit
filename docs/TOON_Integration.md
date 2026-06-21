# TOON Integration — Token-Efficient Prompts

## What is TOON?

**TOON (Token-Oriented Object Notation)** is a compact encoding format for JSON data,
designed specifically for LLM prompts. It saves **~40% tokens** compared to JSON by
declaring array fields once and streaming data as rows.

- **Website:** https://toonformat.dev
- **GitHub:** https://github.com/toon-format/toon
- **Version:** 2.3.0

## Why Use TOON?

| Format | Tokens | Accuracy | Notes |
|--------|--------|----------|-------|
| JSON | 100% | 75.0% | Verbose, repeats field names |
| **TOON** | **~60%** | **76.4%** | Compact, LLM-friendly guardrails |
| YAML | ~80% | 74.2% | Less compact than TOON |
| CSV | ~50% | 70.1% | No nested structure support |

## How TOON Works

### JSON (verbose)
```json
{"users": [
  {"id": 1, "name": "Alice", "role": "admin"},
  {"id": 2, "name": "Bob", "role": "user"},
  {"id": 3, "name": "Charlie", "role": "user"}
]}
```

### TOON (compact)
```yaml
users[3]{id,name,role}:
  1,Alice,admin
  2,Bob,user
  3,Charlie,user
```

**Savings:** Fields declared once, data streamed as rows. ~40% fewer tokens.

## Using TOON with Claude Code

### In System Prompts

When sending structured context to Claude Code, format it in TOON:

```markdown
Project files are listed in TOON format:

files[5]{name,size,type,modified}:
  lib.sh,18317,shell,2026-06-21
  install.sh,4806,shell,2026-06-21
  test_providers.sh,15000,shell,2026-06-21
  CHANGELOG.md,5000,markdown,2026-06-21
  README.md,3000,markdown,2026-06-21

Analyze the codebase structure and suggest improvements.
```

### In Tool Definitions

Format tool schemas in TOON for token efficiency:

```markdown
Available tools in TOON format:

tools[3]{name,description}:
  read_file,Read a file from disk
  write_file,Write content to a file
  search,Search codebase for patterns

Tool parameters:
  read_file: path (required)
  write_file: path (required), content (required)
  search: query (required), path (optional)
```

### In Conversation History

Compress structured data in conversation:

```markdown
Previous analysis results (TOON format):

issues[4]{file,line,severity,message}:
  lib.sh,45,warning,Unused variable
  install.sh,102,error,Missing quotes
  test.sh,78,info,Deprecated syntax
  config.json,12,warning,Unknown key
```

## Toolkit Integration

### CLI Utility

The toolkit includes a TOON utility at `scripts/toon.mjs`:

```bash
# Encode JSON to TOON
node scripts/toon.mjs encode '{"users":[{"id":1,"name":"Alice"}]}'

# Decode TOON to JSON
node scripts/toon.mjs decode 'users[1]{id,name}: 1,Alice'

# Demo with sample data
node scripts/toon.mjs demo

# Encode a JSON file
node scripts/toon.mjs encode-file data.json
```

### Python Wrapper

For Python scripts, use `scripts/toon_encode.py`:

```bash
# Encode JSON string
python3 scripts/toon_encode.py '{"files":[{"name":"lib.sh","size":18317}]}'

# Encode from file
python3 scripts/toon_encode.py --file data.json
```

### In Provider Aliases

When using provider aliases, TOON can reduce token consumption for:
- System prompts with structured context
- Tool definitions sent to models
- File listings and code analysis results
- Conversation history with structured data

**Note:** TOON formats the CONTENT of messages, not the API transport. The API
request body remains JSON (providers require it).

## Token Savings Examples

### File Listing (10 files)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~180 | — |
| TOON | ~110 | **39%** |

### Tool Definitions (5 tools)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~250 | — |
| TOON | ~150 | **40%** |

### User Records (20 users)

| Format | Tokens | Savings |
|--------|--------|---------|
| JSON | ~600 | — |
| TOON | ~350 | **42%** |

## Best Practices

1. **Use for arrays of objects** — TOON excels at tabular data
2. **Declare fields once** — `{id,name,role}` header saves tokens
3. **Use inline primitives** — Strings, numbers, booleans in rows
4. **Fenced code blocks** — Wrap TOON in ` ```toon ` for clarity
5. **Show the format** — LLMs parse TOON naturally once they see the pattern

## Limitations

- **API transport unchanged** — Providers still require JSON in request bodies
- **Nested structures** — Deep nesting reduces savings
- **Mixed types** — Arrays with mixed types use expanded format
- **Model support** — Most models parse TOON naturally, but some may need examples

## References

- [TOON Format Overview](https://toonformat.dev/guide/format-overview.html)
- [Using TOON with LLMs](https://toonformat.dev/guide/llm-prompts.html)
- [Benchmarks](https://toonformat.dev/guide/benchmarks.html)
- [Specification](https://toonformat.dev/reference/spec.html)
