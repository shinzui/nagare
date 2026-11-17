# Lifecycle events (EP-231): the feed's own history, oldest first, never the
# inventory head. The fixture feed holds three app.deployed events.
GET {{base_url}}/v1/events?first=2
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
header "Nagare-Events-Revision" exists
jsonpath "$.edges" count == 2
jsonpath "$.edges[0].node.position" == 0
jsonpath "$.edges[0].node.event.type" == "app.deployed"
jsonpath "$.edges[0].node.event.id" matches "^ev-[0-9a-f]{32}$"
jsonpath "$.pageInfo.hasNextPage" == true
[Captures]
cursor: jsonpath "$.pageInfo.endCursor"
first_id: jsonpath "$.edges[0].node.event.id"
etag: header "ETag"

GET {{base_url}}/v1/events?first=2&after={{cursor}}
HTTP 200
[Asserts]
jsonpath "$.edges" count == 1
jsonpath "$.edges[0].node.position" == 2
jsonpath "$.pageInfo.hasNextPage" == false

GET {{base_url}}/v1/events?first=2
If-None-Match: {{etag}}
HTTP 304

GET {{base_url}}/v1/events/{{first_id}}
HTTP 200
[Asserts]
jsonpath "$.position" == 0
jsonpath "$.event.id" == "{{first_id}}"

GET {{base_url}}/v1/events/ev-00000000000000000000000000000000
HTTP 404
[Asserts]
jsonpath "$.code" == "unknown_event"

GET {{base_url}}/v1/events?type=database.backup.accepted&after={{cursor}}
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_cursor"

GET {{base_url}}/v1/events?last=1
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_page"
