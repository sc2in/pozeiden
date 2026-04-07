/** mermaid flowchart grammar (extracted structural portion) */
%lex
%x string
%x md_string
%x acc_title
%x acc_descr
%x acc_descr_multiline
%x dir
%x vertex
%x text
%x ellipseText
%x trapText
%x edgeText
%x thickEdgeText
%x dottedEdgeText
%x click
%x href
%x callbackname
%x callbackargs
%x shapeData
%x shapeDataStr

%%
accTitle\s*":"\s*                               { this.begin("acc_title");return 'acc_title'; }
<acc_title>(?!\n|;|#)*[^\n]*                    { this.popState(); return "acc_title_value"; }
accDescr\s*":"\s*                               { this.begin("acc_descr");return 'acc_descr'; }
<acc_descr>(?!\n|;|#)*[^\n]*                    { this.popState(); return "acc_descr_value"; }
accDescr\s*"{"\s*                               { this.begin("acc_descr_multiline");}
<acc_descr_multiline>[\}]                       { this.popState(); }
<acc_descr_multiline>[^\}]*                     return "acc_descr_multiline_value";
\@\{                                            { this.pushState("shapeData"); return 'SHAPE_DATA'; }
<shapeData>["]                                  { this.pushState("shapeDataStr"); return 'SHAPE_DATA'; }
<shapeDataStr>["]                               { this.popState(); return 'SHAPE_DATA'; }
<shapeDataStr>[^\"]+                            { return 'SHAPE_DATA'; }
<shapeData>[^}^"]+                              { return 'SHAPE_DATA'; }
<shapeData>"}"                                  { this.popState(); }
"call"[\s]+                                     this.begin("callbackname");
<callbackname>\([\s]*\)                         this.popState();
<callbackname>\(                                { this.popState(); this.begin("callbackargs"); }
<callbackname>[^(]*                             return 'CALLBACKNAME';
<callbackargs>\)                                this.popState();
<callbackargs>[^)]*                             return 'CALLBACKARGS';
<md_string>[^`"]+                               { return "MD_STR"; }
<md_string>[`]["]                               { this.popState(); }
<*>["][`]                                       { this.begin("md_string"); }
<string>[^"]+                                   { return "STR"; }
<string>["]                                     this.popState();
<*>["]                                          this.pushState("string");
"style"                                         return 'STYLE';
"default"                                       return 'DEFAULT';
"linkStyle"                                     return 'LINKSTYLE';
"interpolate"                                   return 'INTERPOLATE';
"classDef"                                      return 'CLASSDEF';
"class"                                         return 'CLASS';
"href"[\s]                                      return 'HREF';
"click"[\s]+                                    { this.begin("click"); }
<click>[\s\n]                                   this.popState();
<click>[^\s\n]*                                 return 'CLICK';
"flowchart-elk"                                 { if(yy.lex.firstGraph()){this.begin("dir");} return 'GRAPH'; }
"graph"                                         { if(yy.lex.firstGraph()){this.begin("dir");} return 'GRAPH'; }
"flowchart"                                     { if(yy.lex.firstGraph()){this.begin("dir");} return 'GRAPH'; }
"subgraph"                                      return 'subgraph';
"end"\b\s*                                      return 'end';
"_self"                                         return 'LINK_TARGET';
"_blank"                                        return 'LINK_TARGET';
"_parent"                                       return 'LINK_TARGET';
"_top"                                          return 'LINK_TARGET';
<dir>(\r?\n)*\s*\n                              { this.popState(); return 'NODIR'; }
<dir>\s*"LR"                                    { this.popState(); return 'DIR'; }
<dir>\s*"RL"                                    { this.popState(); return 'DIR'; }
<dir>\s*"TB"                                    { this.popState(); return 'DIR'; }
<dir>\s*"BT"                                    { this.popState(); return 'DIR'; }
<dir>\s*"TD"                                    { this.popState(); return 'DIR'; }
<dir>\s*"BR"                                    { this.popState(); return 'DIR'; }
<dir>\s*"<"                                     { this.popState(); return 'DIR'; }
<dir>\s*">"                                     { this.popState(); return 'DIR'; }
<dir>\s*"^"                                     { this.popState(); return 'DIR'; }
<dir>\s*"v"                                     { this.popState(); return 'DIR'; }
.*direction\s+TB[^\n]*                          return 'direction_tb';
.*direction\s+BT[^\n]*                          return 'direction_bt';
.*direction\s+RL[^\n]*                          return 'direction_rl';
.*direction\s+LR[^\n]*                          return 'direction_lr';
.*direction\s+TD[^\n]*                          return 'direction_td';
[0-9]+                                          return 'NUM';
\#                                              return 'BRKT';
":::"                                           return 'STYLE_SEPARATOR';
":"                                             return 'COLON';
"&"                                             return 'AMP';
";"                                             return 'SEMI';
","                                             return 'COMMA';
"*"                                             return 'MULT';
<INITIAL,edgeText>\s*[xo<]?\-\-+[-xo>]\s*      { this.popState(); return 'LINK'; }
<INITIAL>\s*[xo<]?\-\-\s*                       { this.pushState("edgeText"); return 'START_LINK'; }
<edgeText>[^-]|\-(?!\-)                         return 'EDGE_TEXT';
<INITIAL,thickEdgeText>\s*[xo<]?\=\=+[=xo>]\s* { this.popState(); return 'LINK'; }
<INITIAL>\s*[xo<]?\=\=\s*                       { this.pushState("thickEdgeText"); return 'START_LINK'; }
<thickEdgeText>[^=]|\=(?!=)                     return 'EDGE_TEXT';
<INITIAL,dottedEdgeText>\s*[xo<]?\-?\.+\-[xo>]?\s* { this.popState(); return 'LINK'; }
<INITIAL>\s*[xo<]?\-\.\s*                       { this.pushState("dottedEdgeText"); return 'START_LINK'; }
<dottedEdgeText>[^\.]|\.(?!-)                   return 'EDGE_TEXT';
<*>\s*\~\~[\~]+\s*                              return 'LINK';
<ellipseText>[-\/\)][\)]                        { this.popState(); return '-)'; }
<ellipseText>[^\(\)\[\]\{\}]|-\!\)             return "TEXT";
<*>"(-"                                         { this.pushState("ellipseText"); return '(-'; }
<text>"])"                                      { this.popState(); return 'STADIUMEND'; }
<*>"(["                                         { this.pushState("text"); return 'STADIUMSTART'; }
<text>"]]"                                      { this.popState(); return 'SUBROUTINEEND'; }
<*>"[["                                         { this.pushState("text"); return 'SUBROUTINESTART'; }
"[|"                                            { return 'VERTEX_WITH_PROPS_START'; }
\>                                              { this.pushState("text"); return 'TAGEND'; }
<text>")]"                                      { this.popState(); return 'CYLINDEREND'; }
<*>"[("                                         { this.pushState("text"); return 'CYLINDERSTART'; }
<text>")))"                                     { this.popState(); return 'DOUBLECIRCLEEND'; }
<*>"((("                                        { this.pushState("text"); return 'DOUBLECIRCLESTART'; }
<trapText>[\\(?=\])][\]]                        { this.popState(); return 'TRAPEND'; }
<trapText>\/(?=\])\]                            { this.popState(); return 'INVTRAPEND'; }
<trapText>\/(?!\])|\\(?!\])|[^\\\[\]\(\)\{\}\/]+ return 'TEXT';
<*>"[/"                                         { this.pushState("trapText"); return 'TRAPSTART'; }
<*>"[\\"                                        { this.pushState("trapText"); return 'INVTRAPSTART'; }
"<"                                             return 'TAGSTART';
">"                                             return 'TAGEND';
"^"                                             return 'UP';
"\|"                                            return 'SEP';
"v"                                             return 'DOWN';
"#"                                             return 'BRKT';
"&"                                             return 'AMP';
([A-Za-z0-9!"\#$%&'*+\.`?\\_\/]|\-(?=[^\>\-\.])|=(?!=))+ { return 'NODE_STRING'; }
"-"                                             return 'MINUS';
<text>"|"                                       { this.popState(); return 'PIPE'; }
<*>"|"                                          { this.pushState("text"); return 'PIPE'; }
<text>")"                                       { this.popState(); return 'PE'; }
<*>"("                                          { this.pushState("text"); return 'PS'; }
<text>"]"                                       { this.popState(); return 'SQE'; }
<*>"["                                          { this.pushState("text"); return 'SQS'; }
<text>(\})                                      { this.popState(); return 'DIAMOND_STOP'; }
<*>"{"                                          { this.pushState("text"); return 'DIAMOND_START'; }
<text>[^\[\]\(\)\{\}\|\"]+                      return "TEXT";
"\""                                            return 'QUOTE';
(\r?\n)+                                        return 'NEWLINE';
\s                                              return 'SPACE';
<<EOF>>                                         return 'EOF';

/lex

%left '^'
%start start

%%

start
  : graphConfig document
  ;

document
  : /* empty */
  | document line
  ;

line
  : statement
  | SEMI
  | NEWLINE
  | SPACE
  | EOF
  ;

graphConfig
  : SPACE graphConfig
  | NEWLINE graphConfig
  | GRAPH NODIR
  | GRAPH DIR FirstStmtSeparator
  ;

ending
  : endToken ending
  | endToken
  ;

endToken
  : NEWLINE | SPACE | EOF
  ;

FirstStmtSeparator
  : SEMI | NEWLINE | spaceList NEWLINE
  ;

spaceList
  : SPACE spaceList
  | SPACE
  ;

statement
  : vertexStatement separator
  | styleStatement separator
  | linkStyleStatement separator
  | classDefStatement separator
  | classStatement separator
  | clickStatement separator
  | subgraph SPACE textNoTags SQS text SQE separator document end
  | subgraph SPACE textNoTags separator document end
  | subgraph separator document end
  | direction
  | acc_title acc_title_value
  | acc_descr acc_descr_value
  | acc_descr_multiline_value
  ;

separator
  : NEWLINE | SEMI | EOF
  ;

vertexStatement
  : vertexStatement link node
  | vertexStatement link node spaceList
  | node spaceList
  | node
  ;

node
  : styledVertex
  | node AMP styledVertex
  ;

styledVertex
  : vertex
  | vertex STYLE_SEPARATOR idString
  ;

vertex
  : idString SQS text SQE
  | idString DOUBLECIRCLESTART text DOUBLECIRCLEEND
  | idString PS PS text PE PE
  | idString '(-' text '-)'
  | idString STADIUMSTART text STADIUMEND
  | idString SUBROUTINESTART text SUBROUTINEEND
  | idString CYLINDERSTART text CYLINDEREND
  | idString PS text PE
  | idString DIAMOND_START text DIAMOND_STOP
  | idString DIAMOND_START DIAMOND_START text DIAMOND_STOP DIAMOND_STOP
  | idString TAGEND text SQE
  | idString TRAPSTART text TRAPEND
  | idString INVTRAPSTART text INVTRAPEND
  | idString TRAPSTART text INVTRAPEND
  | idString INVTRAPSTART text TRAPEND
  | idString
  ;

link
  : linkStatement arrowText
  | linkStatement
  | START_LINK edgeText LINK
  ;

edgeText
  : edgeTextToken
  | edgeText edgeTextToken
  | STR
  | MD_STR
  ;

linkStatement
  : LINK
  ;

arrowText
  : PIPE text PIPE
  ;

text
  : textToken
  | text textToken
  | STR
  | MD_STR
  ;

textNoTags
  : textNoTagsToken
  | textNoTags textNoTagsToken
  | STR
  | MD_STR
  ;

classDefStatement
  : CLASSDEF SPACE idString SPACE stylesOpt
  ;

classStatement
  : CLASS SPACE idString SPACE idString
  ;

clickStatement
  : CLICK CALLBACKNAME
  | CLICK CALLBACKNAME SPACE STR
  | CLICK CALLBACKNAME CALLBACKARGS
  | CLICK HREF STR
  | CLICK STR
  ;

styleStatement
  : STYLE SPACE idString SPACE stylesOpt
  ;

linkStyleStatement
  : LINKSTYLE SPACE DEFAULT SPACE stylesOpt
  | LINKSTYLE SPACE numList SPACE stylesOpt
  ;

numList
  : NUM
  | numList COMMA NUM
  ;

stylesOpt
  : style
  | stylesOpt COMMA style
  ;

style
  : styleComponent
  | style styleComponent
  ;

styleComponent
  : NUM | NODE_STRING | COLON | SPACE | BRKT | STYLE
  ;

idStringToken
  : NUM | NODE_STRING | DOWN | MINUS | DEFAULT | COMMA | COLON | AMP | BRKT | MULT
  ;

textToken
  : TEXT | TAGSTART | TAGEND
  ;

textNoTagsToken
  : NUM | NODE_STRING | SPACE | MINUS | AMP | COLON | MULT | BRKT
  ;

edgeTextToken
  : EDGE_TEXT
  ;

idString
  : idStringToken
  | idString idStringToken
  ;

direction
  : direction_tb
  | direction_bt
  | direction_rl
  | direction_lr
  | direction_td
  ;

%%
