# Recorded viewer relationships, including one whose route is gone.
GET {{base_url}}/v1/access/grants
HTTP 200
[Asserts]
jsonpath "$.edges" count == 3
jsonpath "$.edges[?(@.node.subjectKind == 'team')].node.subjectRelation" == "member"
jsonpath "$.edges[?(@.node.host == 'gone.example.com')].node.subject" == "user_2"
