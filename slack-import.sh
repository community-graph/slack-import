unzip -d $NEO4J_HOME/import neo4j-users\ Slack\ export\ *.zip
cd $NEO4J_HOME/import
find . -mindepth 2 -name "*-*-*.json" | cut -b3- > channels.csv
cd $NEO4J_HOME
$NEO4J_HOME/bin/cypher-shell -u $NEO4J_USER -p $NEO4J_PASSWORD $NEO4J_URL < EOF

create constraint on (c:Channel) assert c.id is unique;
create constraint on (m:Message) assert m.id is unique;
create constraint on (u:User) assert u.id is unique;
create constraint on (t:Team) assert t.id is unique;
create index on :Channel(title);

:param base "file:///var/lib/neo4j/import"

WITH {base} + "/channels.json" as url
call apoc.load.json(url) yield value as channel
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

WITH {base} + "/users.json" as url
call apoc.load.json(url) yield value as user
MERGE (u:User {id:user.id}) ON CREATE SET u:Slack
SET u += apoc.map.removeKeys(apoc.map.merge(user,user.profile),["team_id","tz_label","real_name_normalized","image_24","image_32","image_72","image_192","image_512","image_1024","profile","avatar_hash","fields","image_original"])
MERGE (t:Team {id:user.team_id})
MERGE (u)-[:MEMBER_OF]->(t)
RETURN count(*);


call apoc.periodic.iterate('
LOAD CSV FROM "file:///channels.csv" AS row
RETURN {base} +"/"+ row[0] AS url, split(row[0],"/")[0] AS channel_name
','
MATCH (c:Channel {title:{channel_name}})
CALL apoc.load.json({url}) YIELD value AS msg
WHERE msg.user IS NOT NULL
MATCH (u:User {id:msg.user})
CREATE (u)-[:POSTED]->(m:Message:Content:Slack {text:msg.text, created:msg.ts})-[:IN]->(c)
WITH m,msg
CALL apoc.create.addLabels(m, [
  reduce(s="", x in split(msg.type,"_") |  s + toUpper(substring(x,0,1))+substring(x,1,length(msg.type))) ,  
  reduce(s="", x in split(coalesce(msg.subtype,"Text"),"_") | s + toUpper(substring(x,0,1))+substring(x,1,length(msg.type)))  ]) YIELD node
RETURN count(*);
',{batchSize:1,params:{base:{base}}});

MATCH (c:Channel:Slack)
RETURN c.title,size( ()-[:IN]->(c) ) as messages
ORDER BY messages DESC LIMIT 10;

MATCH (u:User:Slack)
RETURN u.name,size( (u)-[:JOINED]->() ) as channels, size( (u)-[:POSTED]->() ) as messages
ORDER BY messages DESC LIMIT 10;

match (c:Channel)<-[:IN]-(m:Message)<-[:POSTED]-(u) where c.title contains "cypher"
return u.real_name, count(*) order by count(*) desc LIMIT 10;

match (c:Channel)<-[:IN]-(m:Message:Text)<-[:POSTED]-(u) where c.title contains "cypher"
with split(apoc.text.regreplace(toLower(m.text),"\\W+"," ")," ") as words
unwind words as word
with * where length(word) > 3
return word, count(*) order by count(*) desc limit 20;

match (c:Channel)<-[:IN]-(m:Message:Text)<-[:POSTED]-(u) where c.title contains "cypher"
with split(apoc.text.regreplace(toLower(m.text),"\\W+"," ")," ") as words
unwind range(0,length(words)-2) as idx
with words[idx..idx+2] as phrase
with * where any(w IN phrase where length(w) > 3)
return phrase, count(*) order by count(*) desc limit 20;

match (c:Channel)<-[:IN]-(m:Message:Text)<-[:POSTED]-(u) where c.title contains "cypher"
with split(apoc.text.regreplace(toLower(m.text),"\\W+"," ")," ") as words
unwind range(0,length(words)-3) as idx
with words[idx..idx+3] as phrase
with * where size(filter(w IN phrase where length(w) > 3)) > 1 and none(w in phrase where w in ["com"])
return phrase, count(*) order by count(*) desc limit 20;

EOF

exit

WITH {base} + "/users.json" as url
call apoc.load.json(url) yield value as user
RETURN keys(apoc.map.removeKeys(apoc.map.merge(user,user.profile),["team_id","tz_label","real_name_normalized","image_24","image_32","image_72","image_192","image_512","image_1024","profile","avatar_hash"])), count(*)
LIMIT 10;
