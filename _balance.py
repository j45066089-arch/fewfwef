import re,sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
# remove comments and strings while preserving newlines
out=[]; i=0; state='code'; line=1; stack=[]
while i<len(s):
 c=s[i]; n=s[i+1] if i+1<len(s) else ''
 if state=='code':
  if c=='/' and n=='/': state='line'; out+=[' ',' ']; i+=2; continue
  if c=='/' and n=='*': state='block'; out+=[' ',' ']; i+=2; continue
  if c=='"': state='str'; out.append(' '); i+=1; continue
  if c=="'": state='char'; out.append(' '); i+=1; continue
  out.append(c)
  if c in '({[': stack.append((c,line,i))
  elif c in ')}]':
   want={')':'(', '}':'{', ']':'['}[c]
   if not stack or stack[-1][0]!=want: print('MISMATCH',line,c,'top',stack[-1] if stack else None)
   else: stack.pop()
  if c=='\n': line+=1
  i+=1; continue
 if state=='line':
  if c=='\n': state='code'; out.append('\n'); line+=1
  else: out.append(' ')
  i+=1; continue
 if state=='block':
  if c=='*' and n=='/': state='code'; out+=[' ',' ']; i+=2
  else:
   out.append('\n' if c=='\n' else ' '); line+= (c=='\n'); i+=1
  continue
 if state in ('str','char'):
  if c=='\\': out+=[' ',' ']; i+=2; continue
  if (state=='str' and c=='"') or (state=='char' and c=="'"): state='code'
  out.append('\n' if c=='\n' else ' '); line+=(c=='\n'); i+=1
print('remaining',stack[-20:],'count',len(stack))
for ln in range(1020,1190):
 raw=s.splitlines()[ln-1]
 clean=out and ''.join(out).splitlines()[ln-1]
 if any(x in raw for x in ['{','}','%hook','%end','%orig']) or ln in range(1128,1184): print(f'{ln}: {raw}')
