/******************************************
** Ticket #: 
** Name: ABG Critical Values iSTAT v Flowsheets
** Requested By:  
** Desc: This query shows whether a tech has documented on the iSTAT
** device when a critical value is thrown - OR whether the associated
** flowsheet rows were documented on within 5 minutes of the critical value.
** Note: becuase the iSTAT machine does not autofill the flowsheet rows, this
** query can only provide an approximation of whether the rows were filled
** in compliance with the critical value in question - the patient record
** should be considered the source of truth.
** Cols/Summaries:
** Auth: John E Lutz
** Date:#date#
**************************
** Change History
**************************
** PR   Date        Author   Change Ticket #     Description 
** --   --------   -------   ---------------     ------------------------------------
** 1    
*******************************************/

--WITH DATES AS -- Testing dates for SQL Developer
--( 
--SELECT TO_DATE('06/25/2020', 'MM/DD/YYYY') AS START_DATE
--  ,TO_DATE('07/01/2020', 'MM/DD/YYYY') AS END_DATE
--  FROM DUAL
--) -- End CTE

WITH DATES AS -- Use this CTE in Crystal (provides Epic date shortcuts
(
  select 
     min(EPIC_UTIL.EFN_DIN('T-10')) as START_DATE
    ,min(EPIC_UTIL.EFN_DATEADD('d',1,EPIC_UTIL.EFN_DIN('T-2'))) as END_DATE
  from ZC_YES_NO where YES_NO_C = 1
) --End CTE

,ORDERS AS -- Look at all labs resulted using the iSTAT
(
SELECT DISTINCT
  op.ORDER_PROC_ID ORD_ID
  ,op.PAT_ENC_CSN_ID CSN
  ,pat.PAT_MRN_ID MRN
  ,pat.PAT_NAME Pat_Name
  ,loc.LOC_NAME as LOCATION_NAME
  ,dep.DEPARTMENT_NAME as ORDER_DEPT
  ,patenc.INPATIENT_DATA_ID
  ,results.ORD_VALUE
  ,results.RESULT_FLAG_C Flag
  ,results.COMP_RES_TECHNICIA Tech_ID
  ,cle.NAME Tech_Name
  ,results.COMPONENT_ID Comp_ID
  ,cc.NAME Comp_Name
  ,results.ORD_VALUE Comp_Val
  ,results.RESULT_DATE Res_Date
  ,eap.PROC_CODE Proc_ID
  ,eap.PROC_NAME Proc_Name
  ,op2.SPECIMN_TAKEN_TIME Collected
  ,op.RESULT_TIME result_time_1

FROM ORDER_PROC op
  INNER JOIN PAT_ENC_HSP patenc ON op.PAT_ENC_CSN_ID = patenc.PAT_ENC_CSN_ID
  INNER JOIN PATIENT pat ON pat.PAT_ID = patenc.PAT_ID
  INNER JOIN CLARITY_EAP eap on eap.PROC_ID = op.PROC_ID
  INNER JOIN ORDER_PROC_2 op2 on op.ORDER_PROC_ID = op2.ORDER_PROC_ID
  INNER JOIN DATES ON op.ORDERING_DATE BETWEEN dates.START_DATE AND dates.END_DATE
  INNER JOIN ORDER_RESULTS results on results.ORDER_PROC_ID = op.ORDER_PROC_ID
  LEFT JOIN CLARITY_COMPONENT cc ON results.COMPONENT_ID = cc.COMPONENT_ID
  LEFT JOIN CLARITY_EMP cle ON results.COMP_RES_TECHNICIA = cle.SYSTEM_LOGIN
  LEFT JOIN CLARITY_DEP dep ON patenc.DEPARTMENT_ID = dep.DEPARTMENT_ID
  LEFT JOIN CLARITY_LOC loc ON dep.REV_LOC_ID = loc.LOC_ID
WHERE 1=1
  AND results.COMP_RES_TECHNICIA IS NOT NULL -- must be a human tech, not auto read
  AND eap.PROC_NAME LIKE '%ISTAT%'
  AND op2.SPECIMN_TAKEN_TIME IS NOT NULL
) -- End CTE

,flowrow AS (
SELECT 
  flo.DISP_NAME
  ,flo.FLO_MEAS_ID
  ,ce.NAME FLO_Name
  ,CASE WHEN flo.FLO_MEAS_ID IN ('3040101964') 
    THEN TO_CHAR(dd.CALENDAR_DT, 'mm/dd/yyyy') 
    WHEN flo.FLO_MEAS_ID IN ('3040101965') 
    THEN TO_CHAR(EPIC_UTIL.EFN_DATEADD('S',(TO_NUMBER(fsd.MEAS_VALUE)), DATE'1840-12-31'),'HH24:MI') 
    ELSE fsd.MEAS_VALUE END AS MEAS_VALUE_COAL -- Makes Epic version of date and time readable
  ,fsd.EDITED_LINE
  ,ifr.INPATIENT_DATA_ID
  ,fsd.RECORDED_TIME as RECORDED_TIME
FROM IP_FLWSHT_MEAS fsd
  INNER JOIN dates ON fsd.RECORDED_TIME BETWEEN dates.START_DATE AND dates.END_DATE
  INNER JOIN IP_FLWSHT_REC ifr ON fsd.FSD_ID = ifr.FSD_ID
  INNER JOIN IP_FLO_GP_DATA FLO ON fsd.FLO_MEAS_ID = flo.FLO_MEAS_ID
  LEFT JOIN DATE_DIMENSION dd ON fsd.MEAS_VALUE = TO_CHAR(dd.EPIC_DTE)
    AND flo.FLO_MEAS_ID IN ('3040101964')
  LEFT JOIN CLARITY_EMP ce ON fsd.ENTRY_USER_ID = ce.USER_ID
WHERE flo.FLO_MEAS_ID IN ('3040101963','3040101964','3040101965','3040101966')
) -- End CTE

,piv1 AS -- provides the query, combined with pivots for both components and flowsheets
(
SELECT * FROM
(
SELECT
  Tech_ID
  ,Tech_Name
  ,FLO_Name
  ,ORD_ID
  ,CSN
  ,MRN
  ,Pat_Name
  ,Location_Name
  ,Order_Dept
  ,Proc_Name
  ,MAX(Flag) over (partition by ord_id) Flag
  ,Collected
  ,result_time_1
  ,flowrow.RECORDED_TIME FloTime
  ,Comp_ID
  ,Comp_Val
  ,MEAS_VALUE_COAL
  ,FLO_MEAS_ID
FROM orders
  LEFT JOIN flowrow ON flowrow.INPATIENT_DATA_ID = orders.INPATIENT_DATA_ID
    AND flowrow.RECORDED_TIME > result_time_1 -- the flowsheet row must have been filled in after the crit val
    AND (flowrow.RECORDED_TIME - result_time_1) < 0.0035 -- percentage of 1 day, about five minutes 
)
PIVOT
( --component pivot
MAX(Comp_Val) Comp
FOR Comp_ID IN ('8408' Time_Notified,'8409' Prov_Notified,'8410' Prov_Creds,'8411' Readback,'3434' FiO2,'3445' PiP,'3455' Vt,'3444' PEEP,'3458' ETCO2)
)
PIVOT
( -- flowsheet pivot
MAX(MEAS_VALUE_COAL) Flo
  FOR FLO_MEAS_ID IN ('3040101963' Prov_Notified,'3040101964' Date_Notified,'3040101965' Time_Notified,'3040101966' RB)) 
ORDER BY Tech_Name, Tech_Id, ord_id)

SELECT * FROM piv1;
