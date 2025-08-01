################################################################################
# R code for reproducing the analysis in:
#
# Vanoli J, et al. Confounding mechanisms and adjustment strategies in air 
#   pollution epidemiology: a case-study assessment with the UK Biobank cohort. 
#   Under review. 
# http://...
#
# * an updated version of this code, compatible with future versions of the
#   software, is available at:
#   https://github.com/gasparrini/UKB-confounding
################################################################################

################################################################################
# PREPARE THE DATA
################################################################################

# DOWNLOAD SYNTHETIC DATA FROM THE ZENODO REPOSITORY (IF NEEDED)
files <- c("synthbdcohortinfo", "synthbdbasevar", "synthpmdata", "synthoutdeath")
for(x in files) if(! paste0(x,".RDS") %in% list.files("data"))
  download_zenodo("10.5281/zenodo.13983169", path="data", files=paste0(x,".RDS"))

# LOAD COHORT DATASET
bdcohortinfo <- readRDS("data/synthbdcohortinfo.RDS") |> as.data.table()

# LOAD BASELINE VARS (SECOND IMPUTED DATASET)
bdbasevar <- readRDS("data/synthbdbasevar.RDS") |> as.data.table()

# LOAD OUTCOME DATASET, REMOVING DEATHS FOR EXTERNAL CAUSES
outdeath <- readRDS("data/synthoutdeath.RDS") |> as.data.table() |>
  subset(substr(icd10,1,1) %in% icdcode)

# LOAD THE PM DATA, DEFINE THE MOVING AVERAGE
pmdata <- readRDS("data/synthpmdata.RDS") |> as.data.table()
pmdata[, paste0("pm25_",0,lag):=rowMeans(Reduce(cbind, shift(pm25, 0:lag))), 
  by=eid]

# CATEGORIZE CONTINUOUS VARIABLES
bdbasevar <- bdbasevar[,`:=`(
  smkpackyearcat = cut(smkpackyear, c(0,0.5,10,30,60,1000), 
    label=c("0","<=10","10-30", "30-60",">60"), include.lowest=T),
  wthratiocat = factor(ifelse(sex=="Female", cut(wthratio, c(0,0.80,0.85,100), 
    label = c("low", "medium","high")), cut(wthratio, c(0,0.95,1,100), 
      label = c("low", "medium","high"))), labels =c("low", "medium","high")),
  greenspacecat = cut(greenspace, 5, 
    label = paste(c("1th","2nd","3rd","4th","5th"), "quintile")),
  tdicat = cut(tdi, 5, 
    label = paste(c("1th","2nd","3rd","4th","5th"), "quintile")))]

# RELABEL SOME CATEGORICAL VARIABLES
levels(bdbasevar$educ) <- c("Low","Professional","Highschool","College")
levels(bdbasevar$income) <- levels(bdbasevar$income) |> 
  sub(" to ", "-", x=_) |> sub("Less than ", "<", x=_) |>
  sub("Greater than ", "<", x=_)
levels(bdbasevar$alcoholintake) <- c("Never","Occasionally","1-3 a month",
  "1-2 a week", "3-4 a week", "Daily or almost")

# TRANSFORM BASELINE VARIABLES IN UNORDERED FACTORS (FOR REGRESSION MODEL)
ordvar <- names(bdbasevar)[sapply(bdbasevar, is.ordered)]
bdbasevar[, (ordvar):=lapply(.SD, factor, ordered=F), .SDcols=ordvar]

# MERGE THE DATA ACROSS SOURCES: COHORT, OUTCOME, BASELINE VARIABLES
fulldata <- merge(bdcohortinfo, outdeath, all.x=T) |> 
  merge(bdbasevar[, c("eid","asscentre","sex")])

# CREATE YEAR OF BIRTH
fulldata[, birthyear:=year(dob)]

# DEFINE THE EVENT AND EXIT TIME
fulldata[, event:=(!is.na(devent) & devent<=dendfu) + 0]
fulldata[, dexit:=fifelse(event==1, devent, dendfu)]

# EXCLUDE SUBJECTS WITH EVENT BEFORE THE START OF THE FOLLOW-UP
fulldata <- fulldata[dstartfu<dexit]

# SPLIT THE DATA BY CALENDAR YEAR
cut <- year(range(fulldata$dstartfu)[1]):year(range(fulldata$dendfu)[2]) |>
  paste0("-01-01") |> as.Date() |> as.numeric()
fulldata[, `:=`(dstartfu=as.numeric(dstartfu), dexit=as.numeric(dexit))]
fulldata <- survSplit(Surv(dstartfu, dexit, event) ~., fulldata, cut=cut) |> 
  as.data.table()

# ASSIGN THE YEAR AND THE YEAR OF LAG-0 EXPOSURE (MINUS ONE)
fulldata[, year:= year(as.Date(dstartfu, origin=as.Date("1970-01-01")))]
fulldata[, yearexp:= year-1]

# CREATE AGE AT ENTER AND EXIT TIMES (AS DAYS)
fulldata[, `:=`(agestartfu=(dstartfu-as.numeric(dob))/365.25,
  ageexit=(dexit-as.numeric(dob))/365.25)]

# MERGE WITH IMPUTED BASELINE VARS
fulldata <- subset(fulldata, select=-c(sex,asscentre)) |> 
  merge(bdbasevar, by="eid") |> 
  setkey(eid, year)

# MERGE WITH PM DATA USING LAG-0 YEAR DEFINITION
# NB: OMITTING SUBJECTS/PERIODS WITH (PARTIALLY) MISSING EXPOSURE
setkey(fulldata, eid, year)
setkey(pmdata, eid, year)
fulldata <- merge(fulldata, na.omit(pmdata), by.x=c("eid","yearexp"), 
  by.y=c("eid","year"))

# APPROXIMATE AGE GROUPS
fulldata[, agegr:=cut(year-year(dob), breaks=agebreaks, labels=agelabs)]
pmdata <- merge(pmdata, subset(bdcohortinfo, select=c(eid,dob)), by="eid")
pmdata[, agegr:=cut(year-year(dob), breaks=agebreaks, labels=agelabs)]
pmdata[, dob:=NULL]
