# The serving build, not the context's installed release.
GET {{base_url}}/v1/platform/version
HTTP 200
[Captures]
etag: header "ETag"
[Asserts]
header "Content-Type" contains "application/json"
header "Nagare-Head-Revision" not exists
jsonpath "$.contracts" includes 1

GET {{base_url}}/v1/platform/version
If-None-Match: {{etag}}
HTTP 304
[Asserts]
header "ETag" == "{{etag}}"
bytes count == 0

# The published document is served as its checked-in bytes.
GET {{base_url}}/v1/openapi.json
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.openapi" startsWith "3.1"
jsonpath "$.paths['/v1/sites'].get.operationId" == "listSites"
