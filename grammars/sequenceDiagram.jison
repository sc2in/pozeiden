/** mermaid sequence diagram grammar */
%lex
%options case-insensitive
%x ID ALIAS LINE CONFIG CONFIG_DATA
%x acc_title
%x acc_descr
%x acc_descr_multiline

%%
[\n]+                                                           return 'NEWLINE';
\s+                                                             /* skip whitespace */
<ID,ALIAS,LINE>((?!\n)\s)+                                      /* skip same-line whitespace */
<INITIAL,ID,ALIAS,LINE>\#[^\n]*                                 /* skip comments */
\%%(?!\{)[^\n]*                                                 /* skip comments */
[^\}]\%\%[^\n]*                                                 /* skip comments */
([0-9]+(\.[0-9]{1,2})?|\.[0-9]{1,2})(?=[ \n]+)                 return 'NUM';
<ID>\@\{                                                        { this.begin('CONFIG'); return 'CONFIG_START'; }
<CONFIG>[^\}]+                                                  { return 'CONFIG_CONTENT'; }
<CONFIG>\}(?=\s+as\s)                                           { this.popState(); this.begin('ALIAS'); return 'CONFIG_END'; }
<CONFIG>\}                                                      { this.popState(); this.popState(); return 'CONFIG_END'; }
<ID>[^\<\->\->:\n,;@\s]+(?=\@\{)                               { yytext = yytext.trim(); return 'ACTOR'; }
<ID>[^<>:\n,;@\s]+(?=\s+as\s)                                   { yytext = yytext.trim(); this.begin('ALIAS'); return 'ACTOR'; }
<ID>[^<>:\n,;@]+(?=\s*[\n;#]|$)                                 { yytext = yytext.trim(); this.popState(); return 'ACTOR'; }
<ID>[^\n]+                                                      { yytext = yytext.trim(); this.popState(); return 'INVALID'; }
"box"                                                           { this.begin('LINE'); return 'box'; }
"participant"                                                   { this.begin('ID'); return 'participant'; }
"actor"                                                         { this.begin('ID'); return 'participant_actor'; }
"create"                                                        return 'create';
"destroy"                                                       { this.begin('ID'); return 'destroy'; }
<ALIAS>"as"                                                     { this.popState(); this.popState(); this.begin('LINE'); return 'AS'; }
<ALIAS>(?:)                                                     { this.popState(); this.popState(); return 'NEWLINE'; }
"loop"                                                          { this.begin('LINE'); return 'loop'; }
"rect"                                                          { this.begin('LINE'); return 'rect'; }
"opt"                                                           { this.begin('LINE'); return 'opt'; }
"alt"                                                           { this.begin('LINE'); return 'alt'; }
"else"                                                          { this.begin('LINE'); return 'else'; }
"par"                                                           { this.begin('LINE'); return 'par'; }
"par_over"                                                      { this.begin('LINE'); return 'par_over'; }
"and"                                                           { this.begin('LINE'); return 'and'; }
"critical"                                                      { this.begin('LINE'); return 'critical'; }
"option"                                                        { this.begin('LINE'); return 'option'; }
"break"                                                         { this.begin('LINE'); return 'break'; }
<LINE>[^#\n;]*                                                  { this.popState(); return 'restOfLine'; }
"end"                                                           return 'end';
"left of"                                                       return 'left_of';
"right of"                                                      return 'right_of';
"links"                                                         return 'links';
"link"                                                          return 'link';
"properties"                                                    return 'properties';
"details"                                                       return 'details';
"over"                                                          return 'over';
"note"                                                          return 'note';
"activate"                                                      { this.begin('ID'); return 'activate'; }
"deactivate"                                                    { this.begin('ID'); return 'deactivate'; }
"title"\s[^#\n;]+                                               return 'title';
"title:"\s[^#\n;]+                                              return 'legacy_title';
accTitle\s*":"\s*                                               { this.begin("acc_title"); return 'acc_title'; }
<acc_title>[^\n]*                                               { this.popState(); return "acc_title_value"; }
accDescr\s*":"\s*                                               { this.begin("acc_descr"); return 'acc_descr'; }
<acc_descr>[^\n]*                                               { this.popState(); return "acc_descr_value"; }
accDescr\s*"{"\s*                                               { this.begin("acc_descr_multiline"); }
<acc_descr_multiline>[\}]                                       { this.popState(); }
<acc_descr_multiline>[^\}]*                                     return "acc_descr_multiline_value";
"sequenceDiagram"                                               return 'SD';
"autonumber"                                                    return 'autonumber';
"off"                                                           return 'off';
","                                                             return ',';
";"                                                             return 'NEWLINE';
[^\/\\\+\(\)\+<\->\->:\n,;]+([\-]*[^+<\->\->:\n,;]+)*          { yytext = yytext.trim(); return 'ACTOR'; }
"->>"                                                           return 'SOLID_ARROW';
"<<->>"                                                         return 'BIDIRECTIONAL_SOLID_ARROW';
"-->>"                                                          return 'DOTTED_ARROW';
"<<-->>"                                                        return 'BIDIRECTIONAL_DOTTED_ARROW';
"->"                                                            return 'SOLID_OPEN_ARROW';
"-->"                                                           return 'DOTTED_OPEN_ARROW';
\-[x]                                                           return 'SOLID_CROSS';
\-\-[x]                                                         return 'DOTTED_CROSS';
\-[\)]                                                          return 'SOLID_POINT';
\-\-[\)]                                                        return 'DOTTED_POINT';
":"[^#\n;]*                                                     return 'TXT';
":"                                                             return 'TXT';
"+"                                                             return '+';
"-"                                                             return '-';
"()"                                                            return '()';
<<EOF>>                                                         return 'NEWLINE';
.                                                               return 'INVALID';

/lex

%left '^'
%start start

%%

start
  : SPACE start
  | NEWLINE start
  | SD document
  ;

document
  : /* empty */
  | document line
  ;

line
  : SPACE statement
  | statement
  | NEWLINE
  | INVALID
  ;

statement
  : participant_statement
  | 'create' participant_statement
  | 'box' restOfLine box_section end
  | signal 'NEWLINE'
  | autonumber NUM NUM 'NEWLINE'
  | autonumber NUM 'NEWLINE'
  | autonumber off 'NEWLINE'
  | autonumber 'NEWLINE'
  | 'activate' actor 'NEWLINE'
  | 'deactivate' actor 'NEWLINE'
  | note_statement 'NEWLINE'
  | links_statement 'NEWLINE'
  | link_statement 'NEWLINE'
  | title
  | legacy_title
  | acc_title acc_title_value
  | acc_descr acc_descr_value
  | acc_descr_multiline_value
  | 'loop' restOfLine document end
  | 'rect' restOfLine document end
  | opt restOfLine document end
  | alt restOfLine else_sections end
  | par restOfLine par_sections end
  | par_over restOfLine par_sections end
  | critical restOfLine option_sections end
  | break restOfLine document end
  ;

box_section
  : /* empty */
  | box_section box_line
  ;

box_line
  : SPACE participant_statement
  | participant_statement
  | NEWLINE
  ;

option_sections
  : document
  | document option restOfLine option_sections
  ;

par_sections
  : document
  | document and restOfLine par_sections
  ;

else_sections
  : document
  | document else restOfLine else_sections
  ;

participant_statement
  : 'participant' actor AS restOfLine 'NEWLINE'
  | 'participant' actor 'NEWLINE'
  | 'participant_actor' actor AS restOfLine 'NEWLINE'
  | 'participant_actor' actor 'NEWLINE'
  | 'destroy' actor 'NEWLINE'
  ;

note_statement
  : 'note' placement actor text2
  | 'note' 'over' actor_pair text2
  ;

links_statement
  : 'links' actor text2
  ;

link_statement
  : 'link' actor text2
  ;

properties_statement
  : 'properties' actor text2
  ;

details_statement
  : 'details' actor text2
  ;

actor_pair
  : actor ',' actor
  | actor
  ;

placement
  : 'left_of'
  | 'right_of'
  ;

signal
  : actor signaltype '+' actor text2
  | actor signaltype '-' actor text2
  | actor signaltype '()' actor text2
  | actor '()' signaltype actor text2
  | actor '()' signaltype '()' actor text2
  | actor signaltype actor text2
  ;

actor
  : ACTOR
  ;

signaltype
  : SOLID_OPEN_ARROW
  | DOTTED_OPEN_ARROW
  | SOLID_ARROW
  | DOTTED_ARROW
  | BIDIRECTIONAL_SOLID_ARROW
  | BIDIRECTIONAL_DOTTED_ARROW
  | SOLID_CROSS
  | DOTTED_CROSS
  | SOLID_POINT
  | DOTTED_POINT
  ;

text2
  : TXT
  ;

%%
