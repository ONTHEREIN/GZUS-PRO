import { DatedCourse } from './schedule-adjustments'
import { AdjustmentPair, AdjustmentPreview } from './schedule-adjustment-v2'
import { dateText, parseScheduleDate, weekFromDate } from './schedule'

export interface GroupSetting {
  groupId: string; range: 'selected' | 'weeks' | 'future'; fromWeek: number
  mode: 'uniform' | 'dates' | 'individual'; weekday: number; targetStart: number; dates: string[]
}
export interface WeekChoice { week: number; enabled: boolean; selected: boolean }
export interface CourseGroup extends GroupSetting {
  name: string; teacher: string; classroom: string; courses: DatedCourse[]; selectedCount: number; weeks: WeekChoice[]; targetCount: number; rangeIndex: number; modeIndex: number
}
export interface EditorPair extends AdjustmentPair {
  name: string; targetEnd: number; sourceWeek: number; targetWeek: number; split: boolean
}
export interface DayCourses { date: string; label: string; courses: Array<DatedCourse & { selected: boolean }>; count: number; selectedCount: number }
export function groupId(c: DatedCourse): string { return c.groupId || c.itemKey.split('->')[0].replace(/^course:\d{4}-\d{2}-\d{2}:/, '').replace(/(:\d+-\d+)+$/, '') }
export function itemId(p: AdjustmentPair): string { return p.itemId || (p.sourceKeys.length ? p.sourceKeys.join('|') : `day:${p.sourceDate}`) }
export function settingFor(c: DatedCourse, settings: GroupSetting[], week: number): GroupSetting {
  return settings.find(s => s.groupId === groupId(c)) || {groupId:groupId(c),range:'selected',fromWeek:week,mode:'uniform',weekday:c.weekday!,targetStart:c.startSection!,dates:[]}
}
export function groupsFor(courses: DatedCourse[], keys: string[], settings: GroupSetting[], week: number): CourseGroup[] {
  const ids = [...new Set([...courses.filter(c=>keys.includes(c.itemKey)).map(groupId), ...settings.filter(s=>courses.some(c=>groupId(c)===s.groupId)).map(s=>s.groupId)])]
  return ids.map(id=> {
    const all=courses.filter(c=>groupId(c)===id), first=all[0]
    if(!first) throw new Error('教学安排已不存在，请重新选择课程')
    const chosen=all.filter(c=>keys.includes(c.itemKey)).sort((a,b)=>a.date.localeCompare(b.date)||a.startSection!-b.startSection!)
    const s=settingFor(first,settings,week)
    return {...s,rangeIndex:['selected','weeks','future'].indexOf(s.range),modeIndex:['uniform','dates','individual'].indexOf(s.mode),name:first.name,teacher:first.teacher||'',classroom:first.classroom||'',courses:chosen,selectedCount:chosen.length,targetCount:s.dates.length,
      weeks:Array.from({length:30},(_,i)=>({week:i+1,enabled:all.some(c=>Number(c.weeks)===i+1),selected:chosen.some(c=>Number(c.weeks)===i+1)}))}
  })
}
export function dayCourses(courses: DatedCourse[], dates: string[], keys: string[], first: string): DayCourses[] {
  const start=parseScheduleDate(first)!
  return [...dates].sort().map(date=> {
    const day=parseScheduleDate(date)!, rows=courses.filter(c=>c.date===date).sort((a,b)=>a.startSection!-b.startSection!)
    return {date,label:`${date} 周${['日','一','二','三','四','五','六'][day.getDay()]} · 第${weekFromDate(start,day)}周`,count:rows.length,selectedCount:rows.filter(c=>keys.includes(c.itemKey)).length,courses:rows.map(c=>({...c,selected:keys.includes(c.itemKey)}))}
  })
}
export function buildEditorPairs(courses: DatedCourse[], keys: string[], groupSettings: GroupSetting[], settings: AdjustmentPair[], operation: string, sources: string[], targets: string[], first: string, week: number): EditorPair[] {
  const chosen=courses.filter(c=>keys.includes(c.itemKey)).sort((a,b)=>a.date.localeCompare(b.date)||a.startSection!-b.startSection!)
  const a=operation==='partialDay'?[...new Set(chosen.map(c=>c.date))].sort():[...sources].sort(), b=[...targets].sort()
  const monday=parseScheduleDate(first)!
  const decorate=(p:AdjustmentPair,name:string):EditorPair=>({...p,name,targetEnd:p.targetStart+p.sourceEnd-p.sourceStart,sourceWeek:weekFromDate(monday,parseScheduleDate(p.sourceDate)!),targetWeek:weekFromDate(monday,parseScheduleDate(p.targetDate)!),split:false})
  if(operation==='day'||operation==='dayCover') return a.length===b.length?a.map((date,i)=>decorate({itemId:`day:${date}`,sourceDate:date,targetDate:b[i],sourceStart:1,sourceEnd:16,targetStart:1,sourceKeys:operation==='dayCover'?courses.filter(c=>c.date===date).map(c=>c.itemKey):[],action:operation==='dayCover'?'replace':'swap'},operation==='dayCover'?'整日覆盖':'整日课程')):[]
  return chosen.map(c=> {
    const group=settingFor(c,groupSettings,week), old=settings.find(p=>p.sourceKeys.includes(c.itemKey))
    let target=c.date
    if(operation==='partialDay') target=b[a.indexOf(c.date)]||c.date
    else if(group.mode==='individual'&&old)target=old.targetDate
    else if(group.mode==='dates') {const own=chosen.filter(o=>groupId(o)===group.groupId);target=[...group.dates].sort()[own.indexOf(c)]||c.date}
    else {const date=parseScheduleDate(c.date)!;date.setDate(date.getDate()-(date.getDay()+6)%7+group.weekday-1);target=dateText(date)}
    return {...decorate({itemId:c.itemKey,sourceDate:c.date,targetDate:target,sourceStart:old?.sourceStart??c.startSection!,sourceEnd:old?.sourceEnd??c.endSection!,targetStart:old?.targetStart??(operation==='partialDay'?c.startSection!:group.targetStart),sourceKeys:[c.itemKey],action:old?.action||'choose'},c.name),split:old?old.sourceStart!==c.startSection||old.sourceEnd!==c.endSection:false}
  })
}
export function validateEditor(courses: DatedCourse[], keys:string[], groups:CourseGroup[], pairs:EditorPair[], operation:string, sources:string[], targets:string[]):string {
  if(keys.some(k=>!courses.some(c=>c.itemKey===k)))return '部分课程已变化，请清除无效选择后重新选课'
  if((operation==='day'||operation==='dayCover')&&sources.some(d=>targets.includes(d)))return '整日调整的两组日期不能交叉'
  if((operation==='day'||operation==='dayCover')&&(!sources.length||sources.length!==targets.length))return '请选择数量相同的来源日期和目标日期'
  if(operation==='dayCover'&&sources.some(d=>!courses.some(c=>c.date===d)))return '来源日期没有课程，无法移动整日课表'
  if(operation!=='day'&&operation!=='dayCover'&&!keys.length)return '请选择至少一次课程'
  if(operation==='partialDay'&&new Set(courses.filter(c=>keys.includes(c.itemKey)).map(c=>c.date)).size!==targets.length)return '每个有选中课程的来源日期需要一个目标日期'
  if(operation==='course'&&groups.some(g=>g.mode==='dates'&&g.selectedCount!==g.dates.length))return '跨周目标日期数量需要与来源次数一致'
  if(pairs.length>60)return '一次最多调整60项，请减少选择'
  for(const p of pairs){
    if(p.sourceEnd<p.sourceStart||p.targetEnd>16)return `${p.name}节次无效或目标超过第16节，请修改`
    if(p.sourceDate===p.targetDate&&p.sourceStart<=p.targetEnd&&p.targetStart<=p.sourceEnd)return `${p.name}同日来源与目标区间重叠，请设置新时间`
    if(operation==='day'&&!courses.some(c=>c.date===p.sourceDate||c.date===p.targetDate))return '配对两侧均无课，请移除该配对'
  }
  return ''
}
export function parseGroupSettings(value:unknown):GroupSetting[] {
  if(!Array.isArray(value))throw new Error('草稿教学安排设置无效')
  return value.map(v=>{
    if(typeof v!=='object'||v===null)throw new Error('草稿教学安排不是对象')
    const r=v as Record<string,unknown>
    if(typeof r.groupId!=='string'||!['selected','weeks','future'].includes(String(r.range))||!['uniform','dates','individual'].includes(String(r.mode))||typeof r.fromWeek!=='number'||typeof r.weekday!=='number'||typeof r.targetStart!=='number'||!Array.isArray(r.dates)||!r.dates.every(d=>typeof d==='string'&&parseScheduleDate(d)))throw new Error('草稿教学安排字段无效')
    return {groupId:r.groupId,range:r.range as GroupSetting['range'],mode:r.mode as GroupSetting['mode'],fromWeek:r.fromWeek,weekday:r.weekday,targetStart:r.targetStart,dates:r.dates as string[]}
  })
}

export interface ResultCourse extends DatedCourse { changeLabel: string }
export function resultCourses(preview: AdjustmentPreview): ResultCourse[] {
  return preview.after.map(a => {
    const before = preview.before.find(b => a.itemKey === b.itemKey || a.itemKey.startsWith(`${b.itemKey}:`) || a.itemKey.startsWith(`${b.itemKey}->`))
    if (!before) throw new Error(`预览课程缺少来源实例：${a.itemKey}`)
    const same = a.date === before.date && a.startSection === before.startSection && a.endSection === before.endSection
    const retained = a.date === before.date && a.startSection! >= before.startSection! && a.endSection! <= before.endSection!
    const returned = preview.pairs.some(row => row.pair.action === 'swap' && before.date === row.pair.targetDate && before.startSection! <= row.pair.targetStart + row.pair.sourceEnd - row.pair.sourceStart && row.pair.targetStart <= before.endSection! && a.date === row.pair.sourceDate)
    return {...a, changeLabel:same?'未变化':retained?'拆分后保留':returned?'交换返回':'移入'}
  }).filter(a=>a.changeLabel !== '未变化')
}
