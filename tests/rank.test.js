// Run: node tests/rank.test.js   (checks the feed/trending ranking maths that lives in index.html)
const fs=require('fs'), path=require('path');
const src=fs.readFileSync(path.join(__dirname,'..','index.html'),'utf8');
const m=src.match(/\/\*RANK-START\*\/([\s\S]*?)\/\*RANK-END\*\//);
if(!m){ console.error('ranking block not found in index.html'); process.exit(1); }
eval(m[1]+';globalThis.rankFeed=rankFeed;globalThis.trendingPosts=trendingPosts;globalThis.trendingCreators=trendingCreators;');
const assert=require('assert'); const now=Date.parse('2026-10-07T12:00:00Z'), H=36e5;
const mk=(id,by,h,likes=0,comments=0)=>({id,by,likes,comments,at:new Date(now-h*H).toISOString()});
const ctx=(o={})=>Object.assign({now,following:new Set(),subscribed:new Set(),liked:new Map(),live:new Set(),users:new Map()},o);
const ids=r=>r.map(p=>p.id).join(',');
// no signals: newest first
assert.equal(ids(rankFeed([mk('a','x',1),mk('b','y',5),mk('c','z',30)],ctx())),'a,b,c');
// a much more popular post of the same age beats a quiet one
assert.equal(ids(rankFeed([mk('quiet','x',3),mk('hot','y',3,200,40)],ctx())),'hot,quiet');
// but a fresh quiet post beats a 10-day-old viral one
assert.equal(rankFeed([mk('old','x',240,500,100),mk('new','y',1,2,0)],ctx())[0].id,'new');
// subscribed beats followed beats stranger, other things equal
assert.equal(ids(rankFeed([mk('s','s',4,5),mk('f','f',4,5),mk('n','n',4,5)],ctx({subscribed:new Set(['s']),following:new Set(['f'])}))),'s,f,n');
// spread: one creator posting 6 times does not fill the top 6
const spam=[1,2,3,4,5,6].map(i=>mk('p'+i,'spam',i)).concat([mk('o1','o1',8,3),mk('o2','o2',9,3),mk('o3','o3',10,3)]);
const top=rankFeed(spam,ctx()).slice(0,6).filter(p=>p.by==='spam').length; assert.ok(top<=4,'spam in top 6: '+top);
// new small creator gets a nudge
assert.equal(rankFeed([mk('big','b',5,4),mk('tiny','n',5,4)],ctx({users:new Map([['n',{createdAt:new Date(now-2*864e5).toISOString(),followers:3}]])}))[0].id,'tiny');
// liked creators and live creators nudge up
assert.equal(rankFeed([mk('a','a',5,4),mk('b','b',5,4)],ctx({liked:new Map([['b',3]])}))[0].id,'b');
assert.equal(rankFeed([mk('a','a',5,4),mk('b','b',5,4)],ctx({live:new Set(['b'])}))[0].id,'b');
// everything is returned exactly once, nothing mutated
const inp=[mk('a','x',1),mk('b','y',2)]; const r=rankFeed(inp,ctx()); assert.equal(r.length,2); assert.equal(inp[0].id,'a');
assert.deepEqual(rankFeed([],ctx()),[]);
// trending: fast-rising recent beats old with more total likes
assert.equal(trendingPosts([mk('old','x',200,300),mk('rising','y',3,40,10)],now,1)[0].id,'rising');
const cr=[{id:'x',followers:100},{id:'y',followers:5}]; assert.equal(trendingCreators(cr,[mk('r','y',2,80,20)],now,2)[0].id,'y');
// speed: 200 posts
const big=Array.from({length:200},(_,i)=>mk('p'+i,'c'+(i%30),i%90,i%17,i%5)); const t0=Date.now(); rankFeed(big,ctx()); assert.ok(Date.now()-t0<100,'slow');
console.log('rank tests passed');
