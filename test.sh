curl -X POST https://openpages-mcp-server.2c20hyggoq5p.us-south.codeengine.appdomain.cloud/mcp \
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
