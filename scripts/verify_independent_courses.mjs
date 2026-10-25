import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {prepareCourse,importedNetErrors} from '../Engineering/Independent/importer.mjs';
import {netlist} from '../Engineering/Independent/model.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const out=process.argv[2];if(!out)throw Error('Pass an evidence directory.');fs.mkdirSync(out,{recursive:true});
const catalog=JSON.parse(fs.readFileSync(path.join(root,'Engineering/CourseCAD/catalog.json')));
const layouts=JSON.parse(fs.readFileSync(path.join(root,'Engineering/Independent/course-layouts.json')));
const cases=[],failures=[];
for(const example of catalog.cases){
 try{
  const project=prepareCourse(example,layouts),issues=importedNetErrors(project);
  if(issues.length)throw Error(issues.join('; '));
  cases.push({id:example.id,project,source:netlist(project),runs:example.runs,modelPacket:example.modelPacket});
 }catch(error){failures.push({id:example.id,error:error.message});}
}
fs.writeFileSync(path.join(out,'cases.json'),JSON.stringify(cases));
fs.writeFileSync(path.join(out,'course-routing.json'),JSON.stringify({passed:cases.length,failures},null,2));
console.log(JSON.stringify({passed:cases.length,failed:failures.length}));
if(failures.length)process.exitCode=1;
