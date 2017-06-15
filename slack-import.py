# pulling repositories from this API endpoint: https://api.github.com/search/repositories

import os
import time
import requests
from neo4j.v1 import GraphDatabase, basic_auth

neo4jUrl = os.environ.get('NEO4J_URL',"bolt://localhost")
neo4jUser = os.environ.get('NEO4J_USER',"neo4j")
neo4jPass = os.environ.get('NEO4J_PASSWORD',"test")
slackToken = os.environ.get('SLACK_TOKEN',None)

driver = GraphDatabase.driver(neo4jUrl, auth=basic_auth(neo4jUser, neo4jPass))

session = driver.session()

session.run("create constraint on (c:Channel) assert c.id is unique;")
session.run("create constraint on (m:Message) assert m.id is unique;")
session.run("create constraint on (t:Team) assert t.id is unique;")
session.run("create index on :Channel(title);")
# session.run("create constraint on (u:User) assert u.id is unique;")
session.run("create index on :User(id);")

importUsers = """
WITH {base} + "/users.list?token=" + {token} as url
call apoc.load.json(url) yield value.users as user
MERGE (u:User {id:user.id}) ON CREATE SET u:Slack
SET u += apoc.map.removeKeys(apoc.map.merge(user,user.profile),["team_id","tz_label","real_name_normalized","image_24","image_32","image_72","image_192","image_512","image_1024","profile","avatar_hash","fields","image_original"])
MERGE (t:Team {id:user.team_id})
MERGE (u)-[:MEMBER_OF]->(t)
RETURN count(*);
"""

importChannels = """
WITH {base} + "/channels.list?token=" + {token} as url
call apoc.load.json(url) yield value.users as channel
merge (c:Channel {id:channel.id}) ON CREATE SET c.title = channel.name, c.created = toInt(channel.created), c.archived = channel.is_archived, c.general = channel.is_general, c:Slack, c.topic = channel.topic.value, c.purpose = channel.purpose.value
MERGE (creator:User {id:channel.creator}) SET creator:Slack MERGE (creator)-[:CREATED]->(c)
FOREACH (m IN  channel.members | MERGE (u:User {id:m}) SET u:Slack MERGE (u)-[:JOINED]->(c))
SET c.members = size(channel.members)
FOREACH (p IN channel.pins |
   MERGE (m:Message {id:p.id}) ON CREATE SET m:Slack, m.type = p.type, m.created = toInt(p.created)
   MERGE (o:User {id:p.owner}) ON CREATE SET o:Slack MERGE (o)-[:POSTED]->(m)
   MERGE (u:User {id:p.user}) ON CREATE SET u:Slack MERGE (u)-[r:PINNED]->(m) ON CREATE SET r.created = toInt(p.created)
)
RETURN count(*);
"""

importMessages = """
WITH {base} + "/channels.history?count=1000&token=" + {token}+"&channel=" + {channel}  as url

call apoc.load.json(url) yield value as channel

MATCH (c:Channel {id:{channel}})
CALL apoc.load.json({url}) YIELD value AS msg
WHERE msg.user IS NOT NULL
MATCH (u:User {id:msg.user})
CREATE (u)-[:POSTED]->(m:Message:Content:Slack {text:msg.text, created:msg.ts})-[:IN]->(c)
WITH m,msg
CALL apoc.create.addLabels(m, [
  reduce(s="", x in split(msg.type,"_") |  s + toUpper(substring(x,0,1))+substring(x,1,length(msg.type))) ,  
  reduce(s="", x in split(coalesce(msg.subtype,"Text"),"_") | s + toUpper(substring(x,0,1))+substring(x,1,length(msg.type)))  ]) YIELD node
RETURN count(*);
"""

page=1
items=100
tag="Neo4j"
hasMore=True

page=1
items=100
hasMore=True
total=0

base = "https://slack.com/api"

result = session.run(importUsers,{"base":base,"token":slackToken})
print(result.consume().counters)

result = session.run(importChannels,{"base":base,"token":slackToken})
print(result.consume().counters)


while hasMore == True:
    # Build URL.
    # TODO authenticated request
    apiUrl = "https://slack.com/api/channels.list?token="+slackToken
#    if maxDate <> None:
#        apiUrl += "&min={maxDate}".format(maxDate=maxDate)
    response = requests.get(apiUrl, headers = {"accept":"application/json"})
    if response.status_code != 200:
        print(response.status_code,response.text)
    json = response.json()
    total = json.get("ok",0)
#    total = 100
    if json.get("channels",None) != None:
        print(len(json["channels"]))
        result = session.run(importQuery,{"json":json})
        print(result.consume().counters)
        page = page + 1
        
    hasMore = page * items < total
    print("hasMore",hasMore,"page",page,"total",total)

#    if json.get('quota_remaining',0) <= 0:
    time.sleep(10)
#    if json.get('backoff',None) != None:
#        print("backoff",json['backoff'])
#        time.sleep(json['backoff']+5)

session.close()