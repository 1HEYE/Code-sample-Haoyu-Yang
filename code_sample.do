
********************************************************************
* Title: Dual-variant pipeline AFTER reg_mechan_final
* Variants: (A) WITH treatment_trend ; (B) WITHOUT treatment_trend
* Includes: structural Y's
* Also: placebo, CSDID, Bacon on core Ys
********************************************************************

*--------------------------- 0) Setup --------------------------------
capture log close _all
set more off



global path "D:\RA\公司\"
cd "$path"


use reg_mechan_final ,clear

* Keys
capture confirm numeric variable year
if _rc!=0 destring year, replace force

capture confirm numeric variable companyid
if _rc!=0 {
    capture confirm string variable Symbol
    if _rc==0 {
        replace Symbol = strtrim(ustrnormalize(Symbol,"nfc"))
        encode Symbol, gen(companyid)
    }
}
xtset companyid year

*--------------------------- 1) Treatment & timing --------------------
capture drop treated post treated_post rel_time
gen byte treated = (policy_year>0)
gen byte post    = (treated==1 & year>=policy_year)
replace post     = 0 if treated==0
gen byte treated_post = treated*post

gen rel_time = .
replace rel_time = year - policy_year if treated==1

*--------------------------- 2) Transforms / logs ---------------------
capture noisily winsor2 StaffSalaryLevel StaffNumber TotalNumber highwage Size ROA1, cut(1,99) replace

capture drop lnStaffSalaryLevel lnhighwage lnTotalNumber lnStaffNumber
gen lnStaffSalaryLevel = ln(StaffSalaryLevel)
gen lnhighwage         = ln(highwage)
gen lnTotalNumber      = ln(TotalNumber)
gen lnStaffNumber      = ln(StaffNumber)

* City-level covariates (NO 国际互联网用户数)
capture noisily winsor2 pergdp 固定资产投资总额万元 expenditure debt 第一产业增加值占GDP比重 第二产业增加值占GDP比重, cut(1,99) replace
capture noisily winsor2 电信业务总量万元 互联网接入用户, cut(1,99) replace

capture drop lnfixedasset lnpergdp lnexpenditure lndebt lndianxin lnhulianwang
gen lnfixedasset  = ln(固定资产投资总额万元)
gen lnpergdp      = ln(pergdp)
gen lnexpenditure = ln(expenditure)
gen lndebt        = ln(debt)
gen lndianxin     = ln(电信业务总量万元)
gen lnhulianwang  = ln(互联网接入用户)

drop if year<=2010
capture drop t
gen t = year - 2010

* Flexible cubic time interactions (no guoji)
capture drop lndianxin1 lndianxin2 lndianxin3 lnhulianwang1 lnhulianwang2 lnhulianwang3 ai_college1 ai_college2 ai_college3 jijin1 jijin2 jijin3 gaoxinqu1 gaoxinqu2 gaoxinqu3 shifanqu1 shifanqu2 shifanqu3 yijian1 yijian2 yijian3
gen lndianxin1 = lndianxin*t
gen lndianxin2 = lndianxin*t*t
gen lndianxin3 = lndianxin*t*t*t
gen lnhulianwang1 = lnhulianwang*t
gen lnhulianwang2 = lnhulianwang*t*t
gen lnhulianwang3 = lnhulianwang*t*t*t
gen ai_college1 = ai_college*t
gen ai_college2 = ai_college*t*t
gen ai_college3 = ai_college*t*t*t
gen jijin1 = jijin*t
gen jijin2 = jijin*t*t
gen jijin3 = jijin*t*t*t
gen gaoxinqu1 = gaoxinqu*t
gen gaoxinqu2 = gaoxinqu*t*t
gen gaoxinqu3 = gaoxinqu*t*t*t
gen shifanqu1 = shifanqu*t
gen shifanqu2 = shifanqu*t*t
gen shifanqu3 = shifanqu*t*t*t
gen yijian1 = yijian*t
gen yijian2 = yijian*t*t
gen yijian3 = yijian*t*t*t

*--------------------------- 3) Heterogeneity tags --------------------
* ISAI from valid_patents (2011-2018)
capture confirm numeric variable ISAI
if _rc!=0 {
    gen byte __tmp_isai = (inrange(year,2011,2018) & valid_patents!=0 & !missing(valid_patents))
    bysort companyid: egen ISAI = max(__tmp_isai)
    replace ISAI = 0 if missing(ISAI)
    drop __tmp_isai
}
* ISsz from total_patents (2011-2018)
capture confirm numeric variable ISsz
if _rc!=0 {
    gen byte __tmp_issz = (inrange(year,2011,2018) & total_patents!=0 & !missing(total_patents))
    bysort companyid: egen ISsz = max(__tmp_issz)
    replace ISsz = 0 if missing(ISsz)
    drop __tmp_issz
}

* Industry groups
capture confirm numeric variable labor_intensive
if _rc!=0 {
    gen byte labor_intensive = 0
    replace labor_intensive = 1 if inlist(Industry2,"A","B","C13","C15","C17","C18","C20","C21","D","E","G","F","R","H","N","P","C14","C16","C19","C24")
}
capture confirm numeric variable capital_intensive
if _rc!=0 {
    gen byte capital_intensive = 0
    replace capital_intensive = 1 if inlist(Industry2,"C22","C23","C25","C26","C29","C32","C33","K","O","Q","J","L","C31")
}
capture confirm numeric variable tech_intensive
if _rc!=0 {
    gen byte tech_intensive = 0
    replace tech_intensive = 1 if inlist(Industry2,"C38","C35","C34","C27","C41","C39","I","M","C28","C30","C36","C37","C40")
}

*--------------------------- 4) Common macros ------------------------
global BASESAT  i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian)
global BASEPOLY lndianxin1 lndianxin2 lndianxin3 lnhulianwang1 lnhulianwang2 lnhulianwang3 ai_college1 ai_college2 ai_college3 jijin1 jijin2 jijin3 gaoxinqu1 gaoxinqu2 gaoxinqu3 shifanqu1 shifanqu2 shifanqu3 yijian1 yijian2 yijian3
global MACROS   lnpergdp lnexpenditure lndebt 第一产业增加值占GDP比重 第二产业增加值占GDP比重

********************************************************************
* VARIANT A: WITH treatment_trend
********************************************************************
capture drop treatment_trend
gen treatment_trend = treated*t

* ---------- Core outcomes ----------
reghdfe lnStaffSalaryLevel treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnStaffNumber treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

eventdd lnStaffSalaryLevel treatment_trend $BASESAT, timevar(rel_time) method(hdfe, cluster(city) absorb(Symbol year)) noline
eventdd lnStaffNumber      treatment_trend $BASESAT, timevar(rel_time) method(hdfe, cluster(city) absorb(Symbol year)) noline

* ---------- Structural Ys (jishu, shengchan, lowla) ----------
reghdfe jishu     treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe shengchan treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lowla    treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- Recruitment (counts) ----------
capture noisily winsor2 记录数 招聘人数总和替换值1 招聘人数总和替换值2 招聘人数总和替换值5 招聘人数总和替换值10, cut(1,99) replace
capture drop ln记录数 ln招聘人数总和替换值1 ln招聘人数总和替换值2 ln招聘人数总和替换值5 ln招聘人数总和替换值10
gen ln记录数 = ln(记录数 + 1)
gen ln招聘人数总和替换值1 = ln(招聘人数总和替换值1)
gen ln招聘人数总和替换值2 = ln(招聘人数总和替换值2)
gen ln招聘人数总和替换值5 = ln(招聘人数总和替换值5)
gen ln招聘人数总和替换值10 = ln(招聘人数总和替换值10)

reghdfe ln记录数                 treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- Subsidies ----------
capture noisily winsor2 subsidy 人工智能补贴 人才补贴 总补贴, cut(1,99) replace
capture drop lnsubsidyall lnsubsidy lntecsubsidy lnlaborsubsidy
gen lnsubsidyall   = ln(总补贴)
gen lnsubsidy      = ln(subsidy)
gen lntecsubsidy   = ln(人工智能补贴 + 1)
gen lnlaborsubsidy = ln(人才补贴 + 1)

reghdfe lnsubsidyall   treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- Patents ----------
replace total_patents = 0 if missing(total_patents)
replace valid_patents = 0 if missing(valid_patents)
capture noisily winsor2 total_patents valid_patents, cut(1,99) replace
capture drop lntotal_patents lnvalid_patents
gen lntotal_patents = ln(total_patents + 1)
gen lnvalid_patents = ln(valid_patents + 1)

reghdfe lntotal_patents treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lntotal_patents treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnvalid_patents treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- Job-posting wages (subset 2016+) ----------
preserve
drop if year < 2016
capture noisily winsor2 ai_avg_salary avg_salary, cut(1,99) replace
capture drop lnavg_salary lnai_avg_salary
gen lnavg_salary     = ln(avg_salary)
gen lnai_avg_salary  = ln(ai_avg_salary)
gen ai_rate = ai_positions / total_positions
gen byte ifall  = (total_positions < .)
gen byte ifaiall= (ai_positions    < .)

reghdfe lnai_avg_salary treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnai_avg_salary treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnavg_salary    treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ai_rate         treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ifall           treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe ifaiall         treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

restore

* ---------- TFP ----------
capture noisily winsor2 TFP_OP TFP_LP TFP_OLS TFP_FE TFP_GMM, cut(1,99) replace
capture drop perTFP perY
gen perTFP = TFP_OP / L if L>0
gen perY   = Y / L   if L>0

reghdfe TFP_OP  treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe TFP_OP  treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe perTFP  treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe perY    treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- AI investment----------
capture noisily winsor2 人工智能软件投资 人工智能硬件投资 人工智能总投资 人工智能投资水平, cut(1,99) replace
capture drop lnaisoftinvest lnaihardinvest lnaiallinvest
gen lnaisoftinvest = ln(人工智能软件投资)
gen lnaihardinvest = ln(人工智能硬件投资)
gen lnaiallinvest  = ln(人工智能总投资)

reghdfe lnaisoftinvest      treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.ISAI treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.ISsz treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.labor_intensive  treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.tech_intensive   treatment_trend $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.capital_intensive treatment_trend $BASESAT, absorb(year companyid) cluster(city)

* ---------- Placebo on core Ys ----------
quietly reghdfe lnStaffSalaryLevel treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
scalar __b1 = _b[treated_post]
preserve
permute treated_post beta=_b[treated_post], reps(500) rseed(123) saving("sim_lnStaffSalaryLevel_trend1.dta", replace): ///
    reghdfe lnStaffSalaryLevel treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
restore

quietly reghdfe lnStaffNumber treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
scalar __b2 = _b[treated_post]
preserve
permute treated_post beta=_b[treated_post], reps(500) rseed(123) saving("sim_lnStaffNumber_trend1.dta", replace): ///
    reghdfe lnStaffNumber treated_post treatment_trend $BASESAT, absorb(year companyid) cluster(city)
restore

* ---------- CSDID (drop movers if city_id exists) ----------
capture confirm numeric variable city_id
if _rc==0 {
    bysort companyid: egen max_city = max(city_id)
    bysort companyid: egen min_city = min(city_id)
    gen byte multi_city = (max_city != min_city)
    preserve
    drop if multi_city==1
    csdid lnStaffSalaryLevel c.lndianxin c.lnhulianwang c.ai_college c.jijin c.gaoxinqu c.shifanqu i.year#c.yijian treatment_trend, ivar(companyid) time(year) gvar(policy_year) method(drimp) agg(simple)
    estat event, estore(cs_wage_t1)
    csdid lnStaffNumber      c.lndianxin c.lnhulianwang c.ai_college c.jijin c.gaoxinqu c.shifanqu i.year#c.yijian treatment_trend, ivar(companyid) time(year) gvar(policy_year) method(drimp) agg(simple)
    estat event, estore(cs_cnt_t1)
    restore
}

* ---------- Bacon decomposition ----------
ddtiming lnStaffSalaryLevel treated_post $MACROS treatment_trend, i(companyid) t(year)
ddtiming lnStaffNumber      treated_post $MACROS treatment_trend, i(companyid) t(year)

********************************************************************
* VARIANT B: WITHOUT treatment_trend
********************************************************************
capture drop treatment_trend

* ---------- Core outcomes ----------
reghdfe lnStaffSalaryLevel treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffSalaryLevel treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnStaffNumber treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnStaffNumber treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

eventdd lnStaffSalaryLevel $BASESAT, timevar(rel_time) method(hdfe, cluster(city) absorb(Symbol year)) noline
eventdd lnStaffNumber      $BASESAT, timevar(rel_time) method(hdfe, cluster(city) absorb(Symbol year)) noline

* ---------- Structural Ys (jishu, shengchan, lowla) ----------
reghdfe jishu     treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe jishu     treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe shengchan treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe shengchan treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe lowla    treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lowla    treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- Recruitment ----------
reghdfe ln记录数                 treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)

reghdfe ln记录数                 treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值1     treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值2     treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值5     treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe ln招聘人数总和替换值10    treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- Subsidies ----------
reghdfe lnsubsidyall   treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnsubsidyall   treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnsubsidy      treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntecsubsidy   treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnlaborsubsidy treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- Patents ----------
reghdfe lntotal_patents treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe lntotal_patents treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lntotal_patents treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnvalid_patents treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnvalid_patents treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- Job-posting wages ----------
preserve
use "`c(pwd)'/jobblock.dta", clear
reghdfe lnai_avg_salary treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnai_avg_salary treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnai_avg_salary treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnavg_salary    treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnavg_salary    treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe ai_rate         treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ai_rate         treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe ifall           treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifall           treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe ifaiall         treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe ifaiall         treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
restore

* ---------- TFP ----------
reghdfe TFP_OP  treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe TFP_OP  treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe TFP_OP  treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe perTFP  treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe perTFP  treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

reghdfe perY    treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe perY    treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- AI investment (explicit, no loops) ----------
reghdfe lnaisoftinvest      treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.ISAI $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.ISsz $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.labor_intensive  $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.tech_intensive   $BASESAT, absorb(year companyid) cluster(city)

reghdfe lnaisoftinvest      treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaihardinvest      treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe lnaiallinvest       treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)
reghdfe 人工智能投资水平      treated_post##i.capital_intensive $BASESAT, absorb(year companyid) cluster(city)

* ---------- Placebo on core Ys ----------
quietly reghdfe lnStaffSalaryLevel treated_post $BASESAT, absorb(year companyid) cluster(city)
scalar __b3 = _b[treated_post]
preserve
permute treated_post beta=_b[treated_post], reps(500) rseed(123) saving("sim_lnStaffSalaryLevel_trend0.dta", replace): ///
    reghdfe lnStaffSalaryLevel treated_post $BASESAT, absorb(year companyid) cluster(city)
restore

quietly reghdfe lnStaffNumber treated_post $BASESAT, absorb(year companyid) cluster(city)
scalar __b4 = _b[treated_post]
preserve
permute treated_post beta=_b[treated_post], reps(500) rseed(123) saving("sim_lnStaffNumber_trend0.dta", replace): ///
    reghdfe lnStaffNumber treated_post $BASESAT, absorb(year companyid) cluster(city)
restore

* ---------- CSDID (drop movers if city_id exists) ----------
capture confirm numeric variable city_id
if _rc==0 {
    bysort companyid: egen max_city = max(city_id)
    bysort companyid: egen min_city = min(city_id)
    gen byte multi_city = (max_city != min_city)
    preserve
    drop if multi_city==1
    csdid lnStaffSalaryLevel c.lndianxin c.lnhulianwang c.ai_college c.jijin c.gaoxinqu c.shifanqu i.year#c.yijian, ivar(companyid) time(year) gvar(policy_year) method(drimp) agg(simple)
    estat event, estore(cs_wage_t0)
    csdid lnStaffNumber      c.lndianxin c.lnhulianwang c.ai_college c.jijin c.gaoxinqu c.shifanqu i.year#c.yijian, ivar(companyid) time(year) gvar(policy_year) method(drimp) agg(simple)
    estat event, estore(cs_cnt_t0)
    restore
}

* ---------- Bacon decomposition ----------
ddtiming lnStaffSalaryLevel treated_post $MACROS, i(companyid) t(year)
ddtiming lnStaffNumber      treated_post $MACROS, i(companyid) t(year)



/********************************************************************
* Event Study / Parallel Trends block
* Outcomes: lnStaffSalaryLevel, lnStaffNumber
* Variants: with/without treatment_trend; with city FE robustness;
*           alternative time windows
********************************************************************/

* Ensure rel_time exists (relative to policy year, treated only)
capture confirm numeric variable rel_time
if _rc!=0 {
    gen rel_time = .
    replace rel_time = year - policy_year if treated == 1
}

* Base controls used inside eventdd (already defined earlier as $BASESAT):
* $BASESAT == i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian)

******************************************************
* A) WITH treatment_trend
******************************************************

* --- Wage (lnStaffSalaryLevel) ---
eventdd lnStaffSalaryLevel ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- Headcount (lnStaffNumber) ---
eventdd lnStaffNumber ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- City FE robustness (add city to absorb) ---
* Wage
eventdd lnStaffSalaryLevel ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* Headcount
eventdd lnStaffNumber ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- Alternative windows: example 1 (year >= 2012) ---
preserve
keep if year >= 2012

eventdd lnStaffSalaryLevel ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

eventdd lnStaffNumber ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )
restore

* --- Alternative windows: example 2 (2015–2020 only) ---
preserve
keep if inrange(year, 2015, 2020)

eventdd lnStaffSalaryLevel ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

eventdd lnStaffNumber ///
    treatment_trend i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )
restore


******************************************************
* B) WITHOUT treatment_trend
******************************************************

* --- Wage (lnStaffSalaryLevel) ---
eventdd lnStaffSalaryLevel ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- Headcount (lnStaffNumber) ---
eventdd lnStaffNumber ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- City FE robustness (add city to absorb) ---
eventdd lnStaffSalaryLevel ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

eventdd lnStaffNumber ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

* --- Alternative windows: example 1 (year >= 2012) ---
preserve
keep if year >= 2012

eventdd lnStaffSalaryLevel ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

eventdd lnStaffNumber ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )
restore

* --- Alternative windows: example 2 (2015–2020 only) ---
preserve
keep if inrange(year, 2015, 2020)

eventdd lnStaffSalaryLevel ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )

eventdd lnStaffNumber ///
    i.year#c.(lndianxin lnhulianwang ai_college jijin gaoxinqu shifanqu yijian), ///
    timevar(rel_time) ///
    method(hdfe, cluster(city) absorb(Symbol year city)) ///
    noline graph_op( ///
        xlabel(-5(5)-1, nogrid) ///
        xline(0, lpattern(dash) lcolor(gs12) lwidth(thin)) ///
        legend(order(1 "Point Estimate" 2 "95% CI") size(*0.8) position(6) rows(1) region(lc(black))) ///
    )
restore
