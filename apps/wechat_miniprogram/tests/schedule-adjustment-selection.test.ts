import { test } from 'node:test'
import { strict as assert } from 'node:assert'
import { DatedCourse } from '../utils/schedule-adjustments'
import { groupsFor, buildEditorPairs, validateEditor, dayCourses, settingFor } from '../utils/schedule-adjustment-selection'

const courses: DatedCourse[] = [
  {name:'数学',teacher:'教师',classroom:'101',itemKey:'math-1',groupId:'math',date:'2026-09-07',weeks:'1',weekday:1,startSection:3,endSection:4},
  {name:'数学',teacher:'教师',classroom:'101',itemKey:'math-3',groupId:'math',date:'2026-09-21',weeks:'3',weekday:1,startSection:3,endSection:4},
  {name:'数学',teacher:'教师',classroom:'101',itemKey:'other',groupId:'other',date:'2026-09-07',weeks:'1',weekday:1,startSection:4,endSection:4}
]
const first='2026-09-07'
test('同名重叠安排分别分组，跨周保留来源并统一目标',()=>{
  const keys=courses.map(c=>c.itemKey)
  const settings=courses.map(c=>({...settingFor(c,[],1),weekday:2}))
  const groups=groupsFor(courses,keys,settings,1)
  assert.equal(groups.length,2)
  const pairs=buildEditorPairs(courses,keys,settings,[],'course',[],[],first,1)
  assert.deepEqual(pairs.map(p=>p.targetDate),['2026-09-08','2026-09-08','2026-09-22'])
  assert.equal(groups[0].weeks[1].enabled,false)
  assert.equal(validateEditor(courses,keys,groups,pairs,'course',[],[]),'')
})
test('清空安排保留周次设置，跨周目标排序配对并报告数量不符',()=>{
  const setting={...settingFor(courses[0],[],1),mode:'dates' as const,dates:['2026-09-29','2026-09-15']}
  assert.equal(groupsFor(courses,[],[setting],1).length,1)
  const keys=['math-1','math-3']
  const pairs=buildEditorPairs(courses,keys,[setting],[],'course',[],[],first,1)
  assert.deepEqual(pairs.map(p=>p.targetDate),['2026-09-15','2026-09-29'])
  const bad={...setting,dates:['2026-09-15']}
  assert.match(validateEditor(courses,keys,groupsFor(courses,keys,[bad],1),pairs,'course',[],[]),/数量/)
})
test('按天浏览日期不计入配对，部分课程保留节次及即时清单',()=>{
  const dates=['2026-09-07','2026-09-08'], keys=['other']
  const days=dayCourses(courses,dates,keys,first)
  assert.deepEqual(days.map(d=>[d.count,d.selectedCount]),[[2,1],[0,0]])
  const pairs=buildEditorPairs(courses,keys,[],[],'partialDay',dates,['2026-09-09'],first,1)
  assert.equal(pairs.length,1)
  assert.equal(pairs[0].targetStart,4)
  assert.equal(validateEditor(courses,keys,[],pairs,'partialDay',dates,['2026-09-09']),'')
  assert.match(validateEditor(courses,['missing'],[],[],'course',[],[]),/变化/)
})
test('整日覆盖按日期纳入来源全部课程，不产生逐课勾选状态',()=>{
  const pairs=buildEditorPairs(courses,[],[],[],'dayCover',['2026-09-07'],['2026-09-08'],first,1)
  assert.equal(pairs.length,1)
  assert.deepEqual(pairs[0].sourceKeys,['math-1','other'])
  assert.equal(validateEditor(courses,[],[],pairs,'dayCover',['2026-09-07'],['2026-09-08']),'')
})
