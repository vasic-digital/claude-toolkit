#!/usr/bin/env node
/**
 * toon.mjs — TOON (Token-Oriented Object Notation) utility for Claude Toolkit.
 * 
 * Encodes JSON to TOON format for token-efficient LLM prompts.
 * Decodes TOON back to JSON for processing.
 * 
 * Usage:
 *   node toon.mjs encode '{"users":[{"id":1,"name":"Alice"}]}'
 *   node toon.mjs decode 'users[1]{id,name}: 1,Alice'
 *   node toon.mjs encode-file input.json
 *   echo '{"data":...}' | node toon.mjs encode
 */

import { encode, decode } from '@toon-format/toon';

const [,, command, ...args] = process.argv;

function help() {
  console.log(`
TOON Utility — Token-Oriented Object Notation for LLM prompts

Commands:
  encode <json>        Encode JSON string to TOON
  decode <toon>        Decode TOON string to JSON
  encode-file <path>   Encode JSON file to TOON
  decode-file <path>   Decode TOON file to JSON
  demo                 Show encoding demo with sample data
  help                 Show this help

Examples:
  node toon.mjs encode '{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}'
  node toon.mjs encode-file data.json > data.toon
  echo '{"items":[1,2,3]}' | node toon.mjs encode
`);
}

function demo() {
  const sampleData = {
    tools: [
      { name: "read_file", description: "Read a file", parameters: { path: "string" } },
      { name: "write_file", description: "Write a file", parameters: { path: "string", content: "string" } },
      { name: "search", description: "Search codebase", parameters: { query: "string" } }
    ],
    files: [
      { name: "lib.sh", size: 18317, type: "shell" },
      { name: "install.sh", size: 4806, type: "shell" },
      { name: "test_providers.sh", size: 15000, type: "shell" }
    ],
    providers: [
      { id: "poe", models: 382, transport: "router" },
      { id: "deepseek", models: 4, transport: "native" },
      { id: "xiaomi", models: 6, transport: "native" }
    ]
  };

  const json = JSON.stringify(sampleData);
  const toon = encode(sampleData);

  console.log("=== Demo: JSON vs TOON ===\n");
  console.log("JSON (" + json.length + " chars):");
  console.log(json);
  console.log("\nTOON (" + toon.length + " chars):");
  console.log(toon);
  console.log("\nSavings: " + Math.round((1 - toon.length / json.length) * 100) + "% fewer characters");
}

async function main() {
  try {
    switch (command) {
      case 'encode': {
        const input = args.join(' ') || await readStdin();
        const data = JSON.parse(input);
        console.log(encode(data));
        break;
      }
      case 'decode': {
        const input = args.join(' ') || await readStdin();
        const data = decode(input);
        console.log(JSON.stringify(data, null, 2));
        break;
      }
      case 'encode-file': {
        if (!args[0]) { console.error('Error: encode-file requires a filename argument'); process.exit(1); }
        const fs = await import('fs');
        const data = JSON.parse(fs.readFileSync(args[0], 'utf-8'));
        console.log(encode(data));
        break;
      }
      case 'decode-file': {
        if (!args[0]) { console.error('Error: decode-file requires a filename argument'); process.exit(1); }
        const fs = await import('fs');
        const data = decode(fs.readFileSync(args[0], 'utf-8'));
        console.log(JSON.stringify(data, null, 2));
        break;
      }
      case 'demo':
        demo();
        break;
      case 'help':
      default:
        help();
    }
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString().trim();
}

main();
