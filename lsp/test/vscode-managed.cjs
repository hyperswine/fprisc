const fs=require('fs'),assert=require('assert/strict'),vscode=require('vscode');
const path=require('path');
const workspace=process.env.FPR_EDITOR_TEST_WORKSPACE;
if(!workspace)throw Error('Set FPR_EDITOR_TEST_WORKSPACE to an isolated managed test project');
const resultFile=process.env.FPR_EDITOR_TEST_RESULT||path.join(workspace,'editor-test-result.json');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label){const end=Date.now()+25000;while(!test()){if(Date.now()>end)throw Error(label);await sleep(80);}}
exports.run=async()=>{
 const result={status:'running',extension:'hyperswine.fpr-lang',checks:[]};
 try{
  fs.writeFileSync(path.join(workspace,'main.fpr'),'profile base.\nS = use \"std/string\".\ninc x = x + 1.\nmain = print (S.trim \" packaged editor \").\nbroken = packaged_editor_missing.\n');
  const ext=vscode.extensions.getExtension('hyperswine.fpr-lang');assert(ext);assert.equal(ext.packageJSON.version,'0.9.0');await ext.activate();
  const uri=vscode.Uri.file(path.join(workspace,'main.fpr'));const doc=await vscode.workspace.openTextDocument(uri);await vscode.window.showTextDocument(doc);
  await until(()=>vscode.languages.getDiagnostics(uri).some(d=>d.message.includes('packaged_editor_missing')),'packaged compiler diagnostic');result.checks.push('managed packaged compiler diagnostic');
  const edit=new vscode.WorkspaceEdit();edit.replace(uri,new vscode.Range(doc.positionAt(0),doc.positionAt(doc.getText().length)),doc.getText().replace('broken = packaged_editor_missing.\n',''));
  assert(await vscode.workspace.applyEdit(edit));assert(await doc.save());
  await until(()=>!vscode.languages.getDiagnostics(uri).some(d=>d.severity===vscode.DiagnosticSeverity.Error),'fixed-file diagnostics clear');result.checks.push('saved correction clears diagnostics');
  let definition;
  for(let i=0;i<50;i++){definition=await vscode.commands.executeCommand('vscode.executeDefinitionProvider',uri,new vscode.Position(3,17));if(definition?.some(d=>(d.uri||d.targetUri).fsPath.includes('/0.13.0/')))break;await sleep(100);}
  assert(definition?.some(d=>(d.uri||d.targetUri).fsPath.includes('/0.13.0/')),JSON.stringify(definition));result.checks.push('definition resolves into pinned installed std');
  const hoverText=items=>(items||[]).flatMap(h=>h.contents.map(c=>typeof c==='string'?c:c.value||'')).join('\n');
  let hover;
  for(let i=0;i<50;i++){hover=await vscode.commands.executeCommand('vscode.executeHoverProvider',uri,new vscode.Position(2,1));if(hoverText(hover).includes('Int -> Int'))break;await sleep(100);}
  assert(hoverText(hover).includes('Int -> Int'),hoverText(hover));result.checks.push('inferred hover from packaged compiler');
  await vscode.commands.executeCommand('fpr.showToolchain');result.checks.push('active toolchain command');
  result.status='passed';
 }catch(e){result.status='failed';result.error=e.stack;throw e;}finally{fs.writeFileSync(resultFile,JSON.stringify(result,null,2)+'\n');}
};
