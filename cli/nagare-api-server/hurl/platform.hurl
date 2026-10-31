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

# The installed release beside the serving build, as of the last refresh
# (EP-236). The fixture's snapshot records 0.13.0 from a legacy stamp.
GET {{base_url}}/v1/platform/versions
HTTP 200
[Captures]
versions_etag: header "ETag"
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "private, no-cache"
header "Nagare-Head-Revision" not exists
jsonpath "$.document" == "platform-versions"
jsonpath "$.snapshot.available" == true
jsonpath "$.nagare.installed.version.value" == "0.13.0"
jsonpath "$.nagare.installed.version.sourceKind" == "recorded"
jsonpath "$.nagare.installed.payloadId.value" == null
jsonpath "$.nagare.installed.payloadId.reason" == "not_recorded"
jsonpath "$.nagare.comparison.state" matches "^(match|different|unknown)$"
jsonpath "$.nagare.comparison.installedVersion" == "0.13.0"
jsonpath "$.nagare.servingBuild.contracts" contains 1
jsonpath "$.databases[0].declaredVersion.value" == "18"
jsonpath "$.components[0].workloads" count == 2

GET {{base_url}}/v1/platform/versions
If-None-Match: {{versions_etag}}
HTTP 304
[Asserts]
header "ETag" == "{{versions_etag}}"
bytes count == 0

HEAD {{base_url}}/v1/platform/versions
HTTP 200
[Asserts]
header "ETag" == "{{versions_etag}}"
bytes count == 0
