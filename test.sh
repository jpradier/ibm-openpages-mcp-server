# Load OPENPAGES_MCP_URL from .env file
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

curl -X POST "${OPENPAGES_MCP_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"tools/call",
    "params":{
      "name":"execute_openpages_query",
      "arguments":{
        "query":"SELECT [Name] FROM [SOXIssue]",
        "limit":10,
        "format":"json"
      }
    },
    "id":"1"
  }'
