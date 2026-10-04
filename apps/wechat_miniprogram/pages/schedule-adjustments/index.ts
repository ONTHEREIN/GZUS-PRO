import { get, requireSession } from "../../utils/api"
import { academicPeriodLabel, syncAcademicPeriod } from "../../utils/academic"
import { AcademicPeriod } from "../../utils/models"
import { parseAcademicPeriod, parseScheduleSettings } from "../../utils/parsers"
import { dateText, parseScheduleDate, mondayOf, weekFromDate, defaultFirstWeekStart, buildWeekRows, buildWeekDays, WeekRow, WeekDay } from "../../utils/schedule"
import { DatedCourse, fetchDatedCourses, parseDatedCourses } from "../../utils/schedule-adjustments"
import { AdjustmentHistory, AdjustmentPair, AdjustmentPreview, AdjustmentRequest, RestorePreview, commit, history, parseRequest, preview, restore, restorePreview } from "../../utils/schedule-adjustment-v2"

interface CalendarDay { date: string; day: number; selected: boolean; enabled: boolean; count: number }
interface CourseRow extends DatedCourse { selected: boolean }
import { GroupSetting, CourseGroup, DayCourses, EditorPair, groupId, itemId, settingFor, groupsFor, dayCourses, buildEditorPairs, validateEditor, parseGroupSettings, ResultCourse, resultCourses } from "../../utils/schedule-adjustment-selection"
interface HistoryRow extends AdjustmentHistory { expanded: boolean; label: string; count: number }
function draftKey(period: AcademicPeriod): string { const student = wx.getStorageSync("auth.studentId"); if (typeof student !== "string" || !student) throw new Error("当前账号标识缺失，请重新登录"); return `schedule.${student}.adjustmentDraft.${period.year}.${period.term}` }
function historyRows(rows: AdjustmentHistory[]): HistoryRow[] { return [...rows].reverse().map((r) => ({ ...r, expanded: false, label: `${r.metadata?.request.operation === "day" ? "整日交换" : r.metadata?.request.operation === "dayCover" ? "整日覆盖" : r.metadata ? r.metadata.request.operation === "partialDay" ? "按天部分课程" : "课程调课" : "旧版调课"} · ${r.status === "active" ? "已同步 / 生效" : "已撤销"}`, count: r.metadata?.request.pairs.length || r.moves.length || 1 })) }

function draftList(saved: unknown, field: string, legacy: string[]): string[] {
  if (typeof saved !== 'object' || saved === null || !(field in saved)) return [...new Set(legacy)]
  const values = (saved as Record<string, unknown>)[field]
  if (!Array.isArray(values) || !values.every(v => typeof v === 'string' && (field === 'keys' || parseScheduleDate(v)))) throw new Error(`草稿${field}字段无效，请重新选择`)
  return [...new Set(values as string[])]
}

Page({
  data: {
    loading: true, busy: false, error: "", screen: "course", operation: "course" as "course" | "day" | "dayCover" | "partialDay", step: 0, groupIndex: 0,
    period: null as AcademicPeriod | null, periodLabel: "", firstWeekStart: "", week: 1, student: "",
    courses: [] as DatedCourse[], weekCourses: [] as CourseRow[], keys: [] as string[], sources: [] as string[], targets: [] as string[],
    pairs: [] as EditorPair[], groups: [] as CourseGroup[], currentGroup: null as CourseGroup | null, groupSettings: [] as GroupSetting[], sourceDays: [] as DayCourses[], targetDays: [] as DayCourses[], calendarCourses: [] as DayCourses[], weekRows: [] as WeekRow[], weekDays: [] as WeekDay[], validation: "", selectedCount: 0, groupCount: 0, settings: [] as AdjustmentPair[], records: [] as HistoryRow[], activeCount: 0,
    submitLabel: "",
    resultCourses: [] as ResultCourse[], preview: null as AdjustmentPreview | null, restoring: null as HistoryRow | null, restorePreview: null as RestorePreview | null,
    calendar: false, calendarGroup: "source", month: "", calendarDays: [] as CalendarDay[], calendarSelected: [] as string[],
    weekNumbers: Array.from({length:30},(_,i)=>`第${i+1}周`), weekdays: ["周一","周二","周三","周四","周五","周六","周日"], ranges:["仅已选这些次","选择多个周次","从选定周起的后续课程"], targetModes:["保留周次，统一设置时间","跨周日期配对","恢复的逐次目标设置"],
    sections: Array.from({ length: 16 }, (_, n) => `第${n + 1}节`), clientId: "", draft: false, loaded: false,
    summaryOpen: false, selectedCourses: [] as DatedCourse[], expandedItems: [] as string[], invalidCount: 0,
    presetTeacher: "", presetClassroom: "", presetAll: false,
    presetKey: "", presetName: "", presetStart: 0, presetWeekday: 0
  },
  onLoad(options: Record<string, string>) {
    if (!requireSession()) return
    this.setData({ week: Number(options.week) || 1, firstWeekStart: options.firstWeekStart || "", presetTeacher: options.teacher || "", presetClassroom: options.classroom || "", presetAll: options.all === "1", presetKey: options.key || "", presetName: options.name || "", presetStart: Number(options.start) || 0, presetWeekday: Number(options.weekday) || 0, student: String(wx.getStorageSync("auth.studentId") || "") })
    const cachedPeriodData: unknown = wx.getStorageSync("academic.period")
    const cachedPeriod = cachedPeriodData ? parseAcademicPeriod(cachedPeriodData) : null
    if (cachedPeriod) {
      this.setData({ period: cachedPeriod, periodLabel: academicPeriodLabel(cachedPeriod) })
      const cached: unknown = wx.getStorageSync(`${draftKey(cachedPeriod)}.courses`)
      if (cached) this.setData({ courses: parseDatedCourses(cached) })
    }
    this.loadPage()
  },
  async onPullDownRefresh() { await this.loadPage(); wx.stopPullDownRefresh() },
  assertAccount() { if (wx.getStorageSync("auth.studentId") !== this.data.student) throw new Error("账号已切换，请重新打开调课") },
  async loadPage() {
    this.setData({ loading: true, error: "" })
    try {
      this.assertAccount()
      if (!this.data.loaded && this.data.period) {
        const saved: unknown = wx.getStorageSync(draftKey(this.data.period))
        if (saved) {
          const draft = parseRequest(saved)
          const targets = typeof saved === 'object' && saved !== null && 'targets' in saved && Array.isArray(saved.targets) && saved.targets.every((d: unknown) => typeof d === 'string') ? saved.targets as string[] : []
          this.setData({ firstWeekStart: this.data.firstWeekStart || draft.firstWeekStart, groupSettings: typeof saved === "object" && saved !== null && "groupSettings" in saved ? parseGroupSettings(saved.groupSettings) : [], operation: draft.operation, screen: draft.operation === 'course' ? 'course' : 'day', sources: draftList(saved, 'sources', draft.pairs.map(p => p.sourceDate)), keys: draftList(saved, 'keys', draft.pairs.flatMap(p => p.sourceKeys)), targets, settings: draft.pairs, draft: true })
        }
        this.rebuild()
      }
      const period = await syncAcademicPeriod()
      if (this.data.period && (this.data.period.year !== period.year || this.data.period.term !== period.term)) {
        this.setData({period, firstWeekStart:'', courses:[], keys:[], sources:[], targets:[], settings:[], groupSettings:[], expandedItems:[], summaryOpen:false, loaded:false, screen:'course', operation:'course', step:0, draft:false})
      }
      if (!this.data.firstWeekStart) {
        const settings = await get("/settings/schedule", parseScheduleSettings)
        this.setData({ firstWeekStart: settings.firstWeeks[`${period.year}-${period.term}`] || dateText(defaultFirstWeekStart(period)) })
      }
      const start = parseScheduleDate(this.data.firstWeekStart)
      if (!start) throw new Error('第一周日期无效，请在课表设置中重新选择')
      this.setData({firstWeekStart: dateText(mondayOf(start))})
      const [courses, records] = await Promise.all([fetchDatedCourses(period, this.data.firstWeekStart, false), history(period)])
      this.assertAccount()
      wx.setStorageSync(`${draftKey(period)}.courses`, courses.map((c) => ({ ...c, week: Number(c.weeks) })))
      this.setData({ period, courses, records: historyRows(records), activeCount: records.filter((r) => r.status === "active").length, periodLabel: academicPeriodLabel(period) })
      const saved: unknown = wx.getStorageSync(draftKey(period))
      if (saved && !this.data.loaded) {
        const request = parseRequest(saved)
        this.setData({ groupSettings: typeof saved === "object" && saved !== null && "groupSettings" in saved ? parseGroupSettings(saved.groupSettings) : [], operation: request.operation, screen: request.operation === "course" ? "course" : "day", sources: draftList(saved, 'sources', request.pairs.map(p => p.sourceDate)), targets: typeof saved === "object" && saved !== null && "targets" in saved && Array.isArray(saved.targets) && saved.targets.every((d: unknown) => typeof d === "string") ? saved.targets as string[] : [], keys: request.operation === "dayCover" ? [] : draftList(saved, 'keys', request.pairs.flatMap(p => p.sourceKeys)), settings: request.pairs, draft: true })
      } else if (!this.data.loaded && (this.data.presetKey || this.data.presetName)) {
        const matches = courses.filter((c) => this.data.presetKey ? c.itemKey === this.data.presetKey : c.name === this.data.presetName && (c.teacher || "") === this.data.presetTeacher && (c.classroom || "") === this.data.presetClassroom && c.startSection === this.data.presetStart && c.weekday === this.data.presetWeekday && weekFromDate(parseScheduleDate(this.data.firstWeekStart)!, parseScheduleDate(c.date)!) === this.data.week)
        this.setData({ screen: "course", operation: "course" })
        if (matches.length === 1 && !this.data.presetAll) this.setData({ keys: [matches[0].itemKey], sources: [matches[0].date], step: 1 })
      }
      if (saved && !this.data.loaded && !this.data.groupSettings.length && this.data.operation === "course") {
        this.setData({groupSettings: courses.filter(c=>this.data.keys.includes(c.itemKey)).map(c=>({...settingFor(c,[],this.data.week),mode:"individual" as const}))})
      }
      if (saved && !this.data.loaded && this.data.operation === "partialDay") {
        this.setData({operation:"course",screen:"course",step:2,groupSettings:courses.filter(c=>this.data.keys.includes(c.itemKey)).map(c=>({...settingFor(c,[],this.data.week),mode:"individual" as const}))})
      }
      this.setData({ loaded: true }); this.rebuild()
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : "调课页面加载失败" }) }
    finally { this.setData({ loading: false }) }
  },
  enter(event: WechatMiniprogram.BaseEvent) {
    if(this.data.busy)return
    const screen=String(event.currentTarget.dataset.screen)
    if(screen==='history'){this.setData({screen});return}
    this.setData({screen,operation:screen==='day'?'day':'course',step:0,groupIndex:0,keys:[],sources:[],targets:[],settings:[],groupSettings:[]});this.changed()
  },
  back() {if(this.data.busy)return;if(this.data.screen==='course'&&this.data.step>0)this.setData({step:this.data.step-1});else this.setData({screen:this.data.screen==='preview'?(this.data.operation==='course'?'course':'day'):this.data.screen==='restore'?'history':'course'})},
  nextStep(){if(this.data.keys.length)this.setData({step:this.data.step+1})},
  changeWeek(event:WechatMiniprogram.BaseEvent){this.setData({week:Math.max(1,Math.min(30,this.data.week+Number(event.currentTarget.dataset.offset)))});this.rebuild()},
  pickWeek(event:WechatMiniprogram.PickerChange){this.setData({week:Number(event.detail.value)+1});this.rebuild()},
  changeGroup(event:WechatMiniprogram.BaseEvent){this.setData({groupIndex:Math.max(0,Math.min(this.data.groups.length-1,this.data.groupIndex+Number(event.currentTarget.dataset.offset)))});this.rebuild()},
  selectCourse(event:WechatMiniprogram.BaseEvent){
    if(this.data.busy)return
    const key=String(event.currentTarget.dataset.key||this.data.weekCourses[Number(event.currentTarget.dataset.index)]?.itemKey||'')
    const course=this.data.courses.find(c=>c.itemKey===key)
    if(!course)throw new Error('课程实例已不存在，请重新加载')
    const keys=this.data.keys.includes(key)?this.data.keys.filter(k=>k!==key):[...this.data.keys,key]
    const setting=settingFor(course,this.data.groupSettings,this.data.week)
    this.setData({keys,groupSettings:[...this.data.groupSettings.filter(g=>g.groupId!==setting.groupId),setting]});this.changed()
  },
  selectDayCourse(event:WechatMiniprogram.BaseEvent){if(this.data.operation!=="partialDay")return;this.selectCourse(event)},
  changeDayMode(event:WechatMiniprogram.BaseEvent){
    const operation=String(event.currentTarget.dataset.mode) as 'day'|'dayCover'
    this.setData({operation,settings:[],keys:[]});this.changed()
  },
  groupChange(event:WechatMiniprogram.PickerChange){
    const id=String(event.currentTarget.dataset.group), field=String(event.currentTarget.dataset.field), value=Number(event.detail.value)
    const group=this.data.groups.find(g=>g.groupId===id)!
    const setting:GroupSetting={groupId:id,range:group.range,fromWeek:group.fromWeek,mode:group.mode,weekday:group.weekday,targetStart:group.targetStart,dates:group.dates}
    if(field==='range')setting.range=(['selected','weeks','future'] as const)[value]
    if(field==='mode')setting.mode=(['uniform','dates','individual'] as const)[value]
    if(field==='fromWeek')setting.fromWeek=value+1
    if(field==='weekday')setting.weekday=value+1
    if(field==='targetStart')setting.targetStart=value+1
    const own=this.data.courses.filter(c=>groupId(c)===id)
    let keys=this.data.keys
    if(setting.range==='future'&&(field==='range'||field==='fromWeek'))keys=[...keys.filter(k=>!own.some(c=>c.itemKey===k)),...own.filter(c=>Number(c.weeks)>=setting.fromWeek).map(c=>c.itemKey)]
    this.setData({keys,groupSettings:[...this.data.groupSettings.filter(g=>g.groupId!==id),setting],settings:this.data.settings.filter(p=>!own.some(c=>p.sourceKeys.includes(c.itemKey)))});this.changed()
  },
  toggleScopeWeek(event:WechatMiniprogram.BaseEvent){
    const id=String(event.currentTarget.dataset.group), week=Number(event.currentTarget.dataset.week)
    const own=this.data.courses.filter(c=>groupId(c)===id&&Number(c.weeks)===week), all=own.every(c=>this.data.keys.includes(c.itemKey))
    this.setData({keys:all?this.data.keys.filter(k=>!own.some(c=>c.itemKey===k)):[...new Set([...this.data.keys,...own.map(c=>c.itemKey)])]});this.changed()
  },
  selectAll(event:WechatMiniprogram.BaseEvent){
    const id=String(event.currentTarget.dataset.group||''), date=String(event.currentTarget.dataset.date||''), clear=event.currentTarget.dataset.clear===true||event.currentTarget.dataset.clear==='true'
    const own=this.data.courses.filter(c=>id?groupId(c)===id:c.date===date)
    this.setData({keys:clear?this.data.keys.filter(k=>!own.some(c=>c.itemKey===k)):[...new Set([...this.data.keys,...own.map(c=>c.itemKey)])]});this.changed()
  },
  rebuild(){
    const first=parseScheduleDate(this.data.firstWeekStart);if(!first)return
    const groups=groupsFor(this.data.courses,this.data.keys,this.data.groupSettings,this.data.week)
    const pairs=buildEditorPairs(this.data.courses,this.data.keys,this.data.groupSettings,this.data.settings,this.data.operation,this.data.sources,this.data.targets,this.data.firstWeekStart,this.data.week).map(p=>({...p,split:p.split||this.data.expandedItems.includes(itemId(p))}))
    const weekCourses=this.data.courses.filter(c=>Number(c.weeks)===this.data.week).map(c=>({...c,selected:this.data.keys.includes(c.itemKey)}))
    const groupIndex=Math.max(0,Math.min(this.data.groupIndex,groups.length-1))
    this.setData({selectedCourses:this.data.courses.filter(c=>this.data.keys.includes(c.itemKey)),invalidCount:this.data.keys.filter(k=>!this.data.courses.some(c=>c.itemKey===k)).length,groupSettings:groups.map(g=>({groupId:g.groupId,range:g.range,fromWeek:g.fromWeek,mode:g.mode,weekday:g.weekday,targetStart:g.targetStart,dates:g.dates})),groups,currentGroup:groups[groupIndex]||null,groupIndex,pairs,weekCourses,weekRows:buildWeekRows(weekCourses,this.data.week),weekDays:buildWeekDays(first,this.data.week),sourceDays:dayCourses(this.data.courses,this.data.sources,this.data.keys,this.data.firstWeekStart),targetDays:dayCourses(this.data.courses,this.data.targets,this.data.keys,this.data.firstWeekStart),selectedCount:this.data.keys.length,groupCount:groups.filter(g=>g.selectedCount>0).length,validation:validateEditor(this.data.courses,this.data.keys,groups,pairs,this.data.operation,this.data.sources,this.data.targets)})
  },
  changed(){
    this.setData({preview:null,clientId:'',error:'',draft:true});this.rebuild()
    if(!this.data.period)return
    const pairs=this.data.pairs.map(p=>({itemId:itemId(p),sourceDate:p.sourceDate,targetDate:p.targetDate,sourceStart:p.sourceStart,sourceEnd:p.sourceEnd,targetStart:p.targetStart,sourceKeys:p.sourceKeys,action:p.action}))
    wx.setStorageSync(draftKey(this.data.period),{schemaVersion:3,...this.data.period,firstWeekStart:this.data.firstWeekStart,operation:this.data.operation,pairs,targets:this.data.targets,groupSettings:this.data.groupSettings,sources:this.data.sources,keys:this.data.keys})
  },
  openCalendar(event: WechatMiniprogram.BaseEvent) {
    const group = String(event.currentTarget.dataset.group)
    const dates = group.startsWith("group:") ? this.data.groups.find(g=>g.groupId===group.slice(6))!.dates : group === "source" ? this.data.sources : this.data.targets
    this.setData({ calendar: true, calendarGroup: group, calendarSelected: [...dates], month: (dates[0] || this.data.firstWeekStart).slice(0, 7) }); this.buildCalendar()
  },
  closeCalendar() { this.setData({ calendar: false }) },
  monthChange(event: WechatMiniprogram.BaseEvent) {
    const [year, month] = this.data.month.split("-").map(Number), date = new Date(year, month - 1 + Number(event.currentTarget.dataset.offset), 1)
    this.setData({ month: dateText(date).slice(0, 7) }); this.buildCalendar()
  },
  buildCalendar() {
    const [year, month] = this.data.month.split("-").map(Number), first = new Date(year, month - 1, 1), count = new Date(year, month, 0).getDate(), offset = (first.getDay() + 6) % 7

    const start = parseScheduleDate(this.data.firstWeekStart)!, last = new Date(start); last.setDate(last.getDate() + 209)
    const calendarDays: CalendarDay[] = Array.from({ length: offset }, () => ({ date: "", day: 0, selected: false, enabled: false, count: 0 }))
    for (let day = 1; day <= count; day++) { const date = dateText(new Date(year, month - 1, day)); calendarDays.push({ date, day, count: this.data.courses.filter(c=>c.date===date).length, selected: this.data.calendarSelected.includes(date), enabled: date >= this.data.firstWeekStart && date <= dateText(last) }) }
    this.setData({ calendarDays, calendarCourses:dayCourses(this.data.courses,this.data.calendarSelected,this.data.keys,this.data.firstWeekStart) })
  },
  toggleDate(event: WechatMiniprogram.BaseEvent) {
    const date = String(event.currentTarget.dataset.date), row = this.data.calendarDays.find((d) => d.date === date)
    if (!row?.enabled) return
    this.setData({ calendarSelected: this.data.calendarSelected.includes(date) ? this.data.calendarSelected.filter((d) => d !== date) : [...this.data.calendarSelected, date] }); this.buildCalendar()
  },
  confirmDates(){
    const dates=[...this.data.calendarSelected].sort(), group=this.data.calendarGroup
    if(group.startsWith('group:'))this.setData({groupSettings:this.data.groupSettings.map(g=>g.groupId===group.slice(6)?{...g,dates}:g)})
    else if(group==='source')this.setData({sources:dates,keys:this.data.operation==='partialDay'?[...this.data.keys.filter(k=>this.data.courses.some(c=>c.itemKey===k&&dates.includes(c.date))),...this.data.courses.filter(c=>dates.includes(c.date)&&!this.data.sources.includes(c.date)).map(c=>c.itemKey)]:this.data.keys})
    else this.setData({targets:dates})
    this.setData({calendar:false,settings:[]});this.changed()
  },
  sectionChange(event: WechatMiniprogram.PickerChange) {
    if (this.data.busy) return
    const index = Number(event.currentTarget.dataset.index), field = String(event.currentTarget.dataset.field), pair = this.data.pairs[index]
    const changed: AdjustmentPair = { itemId: itemId(pair), sourceDate: pair.sourceDate, targetDate: pair.targetDate, sourceStart: pair.sourceStart, sourceEnd: pair.sourceEnd, targetStart: pair.targetStart, sourceKeys: pair.sourceKeys, action: "choose" }
    if (field === "sourceStart") changed.sourceStart = Number(event.detail.value) + 1
    else if (field === "sourceEnd") changed.sourceEnd = Number(event.detail.value) + 1
    else changed.targetStart = Number(event.detail.value) + 1
    this.setData({ settings: [...this.data.settings.filter((p) => itemId(p) !== itemId(pair)), changed] }); this.changed()
  },
  toggleSplit(event: WechatMiniprogram.BaseEvent) { const id = itemId(this.data.pairs[Number(event.currentTarget.dataset.index)]); this.setData({expandedItems:this.data.expandedItems.includes(id)?this.data.expandedItems.filter(k=>k!==id):[...this.data.expandedItems,id]}); this.rebuild() },
  toggleSummary(){this.setData({summaryOpen:!this.data.summaryOpen})},
  clearInvalid(){ this.setData({keys:this.data.keys.filter(k=>this.data.courses.some(c=>c.itemKey===k)),groupSettings:this.data.groupSettings.filter(g=>this.data.courses.some(c=>groupId(c)===g.groupId))}); this.changed() },
  request():AdjustmentRequest{
    if(!this.data.period)throw new Error('学期信息未加载')
    if(this.data.validation)throw new Error(this.data.validation)
    return {schemaVersion:3,...this.data.period,firstWeekStart:this.data.firstWeekStart,operation:this.data.operation,pairs:this.data.pairs.map(p=>({itemId:itemId(p),sourceDate:p.sourceDate,targetDate:p.targetDate,sourceStart:p.sourceStart,sourceEnd:p.sourceEnd,targetStart:p.targetStart,sourceKeys:p.sourceKeys,action:p.action}))}
  },
  async makePreview() {
    this.setData({ busy: true, error: "" })
    try {
      this.assertAccount()
      const result = await preview(this.request())
      this.setData({settings:result.pairs.map(p=>p.pair)})
      this.rebuild()
      this.assertAccount(); this.setData({ resultCourses: result.ready ? resultCourses(result) : [], preview: result, screen: "preview", submitLabel: !result.ready ? "请先处理批内冲突" : this.data.operation === "day" ? `确认交换这 ${result.pairs.length} 对日期` : this.data.operation === "dayCover" ? `确认覆盖并移动这 ${result.pairs.length} 天` : `确认调整这 ${result.pairs.length} 次课程`, clientId: `mini-${Date.now()}-${Math.random().toString(36).slice(2)}` })
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : "调课预览失败" }) }
    finally { this.setData({ busy: false }) }
  },
  async chooseAction(event: WechatMiniprogram.BaseEvent) {
    const pair = this.data.preview!.pairs[Number(event.currentTarget.dataset.index)].pair
    const action = String(event.currentTarget.dataset.action) as "swap" | "replace"
    this.setData({ settings: [...this.data.settings.filter((p) => itemId(p) !== itemId(pair)), { ...pair, action }] }); this.changed(); await this.makePreview()
  },
  async submit() {
    if (!this.data.preview?.ready || this.data.busy) return
    this.setData({ busy: true, error: "" })
    try {
      this.assertAccount(); await commit(this.request(), this.data.clientId, this.data.preview.fingerprint); this.assertAccount()
      wx.removeStorageSync(draftKey(this.data.period!))
      this.setData({ sources: [], targets: [], keys: [], settings: [], groupSettings: [], pairs: [], preview: null, screen: "history", draft: false })
      await this.loadPage(); wx.showToast({ title: "已同步到云端", icon: "success" })
    } catch (error) { this.setData({ error: error instanceof Error ? error.message : "调课提交失败", preview: null, screen: this.data.operation === "course" ? "course" : "day" }) }
    finally { this.setData({ busy: false }) }
  },
  expandRecord(event: WechatMiniprogram.BaseEvent) { const index = Number(event.currentTarget.dataset.index); this.setData({ [`records[${index}].expanded`]: !this.data.records[index].expanded }) },
  async previewUndo(event: WechatMiniprogram.BaseEvent) {
    const row = this.data.records.find((r) => r.clientId === event.currentTarget.dataset.id)
    if (!row || this.data.busy) return
    this.setData({ busy: true, error: "" })
    try { this.assertAccount(); const result = await restorePreview(row, this.data.firstWeekStart); this.assertAccount(); this.setData({ restorePreview: result, restoring: row, screen: "restore" }) }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : "撤销预览失败" }) }
    finally { this.setData({ busy: false }) }
  },
  async undo() {
    if (!this.data.restoring || !this.data.restorePreview || this.data.restorePreview.blockers.length || this.data.busy) return
    this.setData({ busy: true, error: "" })
    try { this.assertAccount(); await restore(this.data.restoring, this.data.firstWeekStart, this.data.restorePreview.fingerprint); this.assertAccount(); this.setData({ screen: "history", restorePreview: null }); await this.loadPage() }
    catch (error) { this.setData({ error: error instanceof Error ? error.message : "撤销失败", restorePreview: null, screen: "history" }) }
    finally { this.setData({ busy: false }) }
  }
})
