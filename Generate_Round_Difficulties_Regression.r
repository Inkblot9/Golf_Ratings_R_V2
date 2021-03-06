

###  This file is for running a linear regression on tall golf data  ###

#  By Daniel Myers

###

### Libraries ####

library(plyr)
library(tidyverse)
library(lubridate)
library(rvest)
library(broom)
library(glmnet)
library(magrittr)


### Function to create sparse matrix ###

# This function is from https://gist.github.com/kotaishr/75a7912ab3e0d0af3847ee0fdec29205
# It converts a dataframe to a standard sparse matrix
data.frame.2.sparseMatrix <- function(df) {
  dtypes = lapply(df, class)
  nrows = dim(df)[1]
  ncols = dim(df)[2]
  
  for (col_idx in 1:ncols) {
    # convert target column into sparseMatrix with colname(s)
    colname = colnames(df)[col_idx]
    if(dtypes[col_idx] == 'factor'){
      col_in_sprMtx = sparse.model.matrix(as.formula(paste("~-1+", colname)), df)
    }
    else{
      col_in_sprMtx = sparseMatrix(i=1:nrows, j=rep(1, nrows), x=df[, col_idx], dims = c(nrows, 1))
      colnames(col_in_sprMtx) = c(colname)
    }
    col_in_sprMtx = drop0(col_in_sprMtx)
    
    # Add column in sparseMatrix form to the result sparseMatrix
    if(col_idx == 1){
      result = col_in_sprMtx
    }
    else{
      result = cbind(result, col_in_sprMtx)
    }
  }                             
  return(result)
}


###  Import Player Results Data ###

Player_Result_Folder <- "Data/Player_Results/"
Player_Result_File_List <- dir(Player_Result_Folder, pattern="Player_Results_.*\\.csv")
Player_Results <- Player_Result_File_List %>%
  map_dfr(~ read.csv(file.path(Player_Result_Folder,.),stringsAsFactors = FALSE)) %>%
  .[!is.na(.$Event_Date),]

Player_Results$Year <- NULL
Player_Results$Event_Date <- as.Date(Player_Results$Event_Date)

# Add Round_ID variable
Player_Results$Round_ID <-
  paste(Player_Results$Event_ID,Player_Results$Round_Num,sep = "_") %>% as.factor()
Player_Results$Player_ID %<>% as.factor()

# Identify if round is part of a Primary Tour:
Primary_Tours <-
  c("European Tour",
    "Major Championship",
    "PGA Tour", 
    "World Golf Championships",
    "Olympic Golf Competition")

Player_Results$Primary_Round <-
  pmin((3 - (as.integer(is.na((match(Player_Results$Event_Tour_1,Primary_Tours)))) +  
          as.integer(is.na((match(Player_Results$Event_Tour_2,Primary_Tours)))) + 
          as.integer(is.na((match(Player_Results$Event_Tour_3,Primary_Tours)))))),1)

# If there are multiple player_names for a given Player_ID, use most common Player_Name for all
Player_Results %<>% group_by(Player_ID) %>%
  mutate(Player_Name = names(table(Player_Name))[table(Player_Name) == max(table(Player_Name))][1]) %>% 
  ungroup() %>% as.data.frame()

str(Player_Results)


### Function to select data to use in Regression ###

Filter_Player_Results<- function(Raw_Data=Player_Results,
                                 Begin_Date="1990-01-01",
                                 End_Date="2050-01-01",
                                 Player_Min_Rounds=0,
                                 Tourn_Min_Players=0){
  
  Filtered_Results <- Raw_Data %>% filter(Event_Date>Begin_Date) %>%
    filter(Event_Date<End_Date)
  
  Filtered_Results %<>%
    semi_join(Filtered_Results %>% count(Player_ID) %>% filter (n>Player_Min_Rounds)) %>% 
    semi_join(Filtered_Results %>% count(Round_ID) %>% filter (n>Tourn_Min_Players)) %>% 
    semi_join(Filtered_Results %>% count(Player_ID) %>% filter (n>Player_Min_Rounds)) %>% 
    semi_join(Filtered_Results %>% count(Round_ID) %>% filter (n>Tourn_Min_Players)) %>%
    droplevels()
  
  str(Filtered_Results)

  return(Filtered_Results)
}


### Function to develop weighting vector from dates and exponent

Weight_Vector <- function (Source_Data, 
                           Key_Date = Sys.Date(), 
                           Weight_Weekly_Exponent = 1, 
                           Date_Name = "Event_Date") {
  # Note: the defaults are to weight all data equally,
  # to set the "key date" to today, and to use the default
  # name for the date column in the source data
  
  # Eventually figure out how to do this dynamically with "Date_Name"
  Date_Vector <- Source_Data$Event_Date  

  Week_Delta <-   as.integer(round(abs(as.integer(as.Date(Key_Date) - Date_Vector)) / 7))
  
  Weights <- as.data.frame(Weight_Weekly_Exponent ^ Week_Delta) %>% set_names(c("Weight"))
  
  return(Weights[,c("Weight")])
  
}


# Test_weights <- Weight_Vector(Player_Results, "2016-01-01",0.99)


### Ridge Regression and Linear Regression as a function ###

LM_Regression_Ratings <- function(Source_Data, Weights_Vector, Player_Info, RegType = "Linear") {
  
  
  str(Weights_Vector)
  
  #Pull out the data that will be needed for the regression
  Variables_Sparse_Reg <- Source_Data[,c("Round_ID","Player_ID")]
  Response_Vector <- as.vector(Source_Data[,c("Score")])
  str(Variables_Sparse_Reg)
  str(Response_Vector)
  
  #Convert to sparse matrix
  Matrix_Sparse_Reg <- data.frame.2.sparseMatrix(Variables_Sparse_Reg)
  str(Matrix_Sparse_Reg)
  
  
  # Elastic Net
  # Elastic Net only keeps those variables that are clearly non-zero.
  
  # fit_elastic <- glmnet(Matrix_Sparse_Reg,Response_Vector)
  # cv_elastic <- cv.glmnet(Matrix_Sparse_Reg,Response_Vector,nfolds=10)
  # pred_elastic <- predict(fit_elastic, Matrix_Sparse_Reg,type="response", s=cv_elastic$lambda.min)
  # plot(fit_elastic)
  # plot(cv_elastic)
  # head(coef(cv_elastic, s = "lambda.min"))
  # print(cv_elastic$lambda.min)
  
  # Ridge Regression
  # Ridge regression keeps all variables, but cross validates a shrinkage
  # parameter which pushes all variables towards 0
  
  lambda_grid=10^seq(4,-10,length=100)
  str(lambda_grid)
  fit_ridge <- glmnet(Matrix_Sparse_Reg,
                      Response_Vector, 
                      weights = Weights_Vector, 
                      alpha = 0, 
                      lambda=lambda_grid)
  cv_ridge <- cv.glmnet(Matrix_Sparse_Reg,
                        Response_Vector, 
                        weights = Weights_Vector, 
                        nfolds=10, 
                        alpha = 0, 
                        lambda=lambda_grid)
  pred_ridge <- predict(fit_ridge, 
                        Matrix_Sparse_Reg,
                        type="response", 
                        s=cv_ridge$lambda.min)
  Ridge_Results <- tidy(coef(cv_ridge, s = "lambda.min"))
  plot(cv_ridge)
  print(cv_ridge$lambda.min)
  
  # The minimum lambda is basically standard linear regression:
  LM_Results <- tidy(coef(cv_ridge, s = min(lambda_grid)))
  
  qplot(Ridge_Results$value[-1],LM_Results$value[-1])
  
  max(Ridge_Results$value)
  max(LM_Results$value)
  min(Ridge_Results$value)
  min(LM_Results$value)
  
  # Split Results Out
  Ridge_Intercept <- Ridge_Results$value[1]
  Ridge_Rounds <- Ridge_Results[grep("Round",Ridge_Results$row),] %>% 
    mutate(Round_ID = as.factor(gsub("^.*ID","",row))) %>%
    select(.,Round_ID, Round_Value = value) 
  Ridge_Players <- Ridge_Results[grep("Player",Ridge_Results$row),] %>% 
    mutate(Player_ID = as.factor(gsub("^.*ID","",row))) %>%
    select(.,Player_ID, Player_Value = value) 
  
  
  Ridge_Results <- list(Ridge_Intercept,Ridge_Rounds,Ridge_Players)
  
  # Split Results Out
  LM_Intercept <- LM_Results$value[1]
  LM_Rounds <- LM_Results[grep("Round",LM_Results$row),] %>% 
    mutate(Round_ID = as.factor(gsub("^.*ID","",row))) %>%
    select(.,Round_ID, Round_Value = value) 
  LM_Players <- LM_Results[grep("Player",LM_Results$row),] %>% 
    mutate(Player_ID = as.factor(gsub("^.*ID","",row))) %>%
    select(.,Player_ID, Player_Value = value) %>%
    merge(.,Player_Info, by = "Player_ID") %T>% str()
  
  Avg_Primary_Rating <- mean(LM_Players$Player_Value[LM_Players$Primary_Player==1]) %T>% print()
  
  LM_Players %<>% mutate(Player_Value = Player_Value - Avg_Primary_Rating)
  LM_Rounds %<>% mutate(Round_Value = Round_Value + Avg_Primary_Rating + LM_Intercept)
  
  LM_Results <- list(LM_Rounds,LM_Players)
 


  if (RegType=="Ridge"){
    Results <- Ridge_Results
  } else {
    Results <- LM_Results
  }

  return(Results)
  
}
  

### Function to compile information about players & Tournaments ###

Player_Information <- function(Source_Data, Weight, Key_Date = Sys.Date()) {
  
  Key_Date <- as.Date(Key_Date)
  
  Player_Summary <- Source_Data %>% mutate(Weights = Weight) %>%
    group_by(Player_Name, Player_ID) %>% 
    summarize(Num_Rounds = n(),
               Sum_Primary = sum(Primary_Round*Weights),
               Sum_Weight = sum(Weights),
               Primary_Ratio = sum(Primary_Round*Weights)/sum(Weights),
               Primary_Player = round(sum(Primary_Round*Weights)/sum(Weights))
               )
  
  Min_Date <- min(Source_Data$Event_Date)
  Max_Date <- max(Source_Data$Event_Date)
  Data_Span <- as.duration(Max_Date - Min_Date)
  
  # Use closest 1 year of data to the key date that is in the data set
  
  if (Data_Span <= dyears(1)) {
    Max_Date_Use <- Max_Date
    Min_Date_Use <- Min_Date
  } else if (Min_Date >= (Key_Date - dyears(0.5))) {
    Min_Date_Use <- Min_Date
    Max_Date_Use <- Min_Date + dyears(1)
  } else if (Max_Date <= (Key_Date + dyears(0.5))) {
    Max_Date_Use <- Max_Date
    Min_Date_Use <- Max_Date - dyears(1)
  } else {
    Min_Date_Use <- as.Date(Key_Date - dyears(0.5))
    Max_Date_Use <- as.Date(Key_Date + dyears(0.5))
  }
  
  
  
  return (list(Min_Date_Use, Max_Date_Use))
  
}





### Select data to use in regression ###

# Use this to establish where to center weighting and player information
Date_of_Interest <- Sys.Date()

Results_Source <- Filter_Player_Results(Player_Results, "2014-01-01", "2018-10-01", 40, 15) 

Weights_Vector <- Weight_Vector(Results_Source, Date_of_Interest, 0.97)

Player_Information_Trial <- Player_Information(Results_Source, Weights_Vector, Date_of_Interest)

Current_Regression <- LM_Regression_Ratings(Results_Source, Weights_Vector, Player_Information_Trial, "Linear")


Player_Ratings <- Current_Regression[[2]] %>% 
  left_join(.,Player_Results[,c("Player_ID","Player_Name","Country")]) %>%
  unique() %>% mutate (Rank = rank(Player_Value)) %>% .[order(.$Rank),] %>%
  .[,c("Rank",
       "Player_Name",
       "Player_Value",
       "Country",
       "Player_ID")] %T>%
  write.csv(
    .,file = (
      "Output/Trial_Ratings_US_Open_2018.csv"
    ), row.names = FALSE
  )


# Results_Source <- Filter_Player_Results(Player_Results,"2015-10-01","2017-10-01",40,15) 
# 
# Trial_Regression1617 <- LM_Regression_Ratings(Results_Source,1,"Linear")
# 
# # Checking to see how using before/after affecting rating of round difficulties
# 
# Compare_overlap_rounds <- merge(Trial_Regression1415[2],Trial_Regression1617[2], by = "row")
# 
# qplot(Compare_overlap_rounds$value.x,Compare_overlap_rounds$value.y)














# ### Primary Variables to Adjust ####
# 
# Input_Date <-  # Sys.Date()
#    as.Date("2010-03-29")   # This regression will do the XX years prior to this date
# Split_Type <-
#   "Before"                 # "Before" or "After" .. This also controls weighting type (exponential for before, Step after)
# 


Golf_Ratings_Regression <- function(Split_Date = Sys.Date(),Split_Type = "Before"){
  
Split_Date <- as.Date(Split_Date)

Rating_Date <- Split_Date + (4 - wday(Split_Date))   # Wednesday of the rated week

Prev_Rating_Date <- Rating_Date -7         # Wednesday prior to rated week

Exponential_Decay_Constant <- 0.98
Step_Weights <-
  c(1,0.25,0.1)           # Vector of 3 numbers, first for end of split season, then for each of following seasons


Min_Player_Rounds <-
  50                     # The sufficient number of rounds by a player to include that player (50)
Min_Player_Rounds_Last_Yr <-
  20                      # The sufficient number of rounds by a player to include that player (25)

Minimum_Player_In_Round <-
  15                      # The minimum number of players present in a round to include it (17)

Save_Location <-  paste0("Output/Archive/Golf_Ratings_",Rating_Date,".csv")

Previous_Ratings <-   paste0("Output/Archive/Golf_Ratings_",Prev_Rating_Date,".csv")


# Output the Rating_Date
cat("The current rating is for the date", format(Rating_Date, "%Y-%m-%d"),".\n")


### Import from CSV File ######



# Results_Source_old <- read.csv(("Data/Tournament_Results_Since_2007_Results_for_LM.csv"))
Results_Source <- read.csv(("Data/Player_Results_RVest.csv"))

Results_Source$Round_ID <-
  paste(Results_Source$Event_ID,Results_Source$Round_Num,sep = "_")
Results_Source$Tour_Name <- Results_Source$Event_Tour_1

#Results_Source <-
#  fread("Data/Tournament_Results_Since_2007_Results_for_LM.csv.gz")
#Results_Source <- as.data.frame(Results_Source)

Results_Source$Event_Date <- as.Date(Results_Source$Event_Date)

Factor_Cols <- c("Player_Name","Player_ID","Country","Event_Name","Event_ID","Round_ID","Tour_Name")
Results_Source[Factor_Cols] <-
  lapply(Results_Source[Factor_Cols],as.factor)
remove(Factor_Cols)



#View(Results_Source)
str(Results_Source)




### Choose what players & Rounds to include in regression  ####


Target_Subset <-
  Remove_Rare_Data (Target_Subset)

str(Target_Subset)





###  Player Information Developed ####

Player_Info <-
  subset(
    Target_Subset, select = c(
      Player_ID,Player_Name,Rounds_Player,Rounds_Last_Year,Primary_Player,Country,Tour_Name,Weight,Event_Date,Week_Delta
    )
  )

# Find out most common tour and total weight over entire ratings interval
Player_ID_Group <- group_by(Player_Info,Player_ID)
Common_Tour <- summarise(Player_ID_Group,
                         Common_Tour = names(which.max(table(Tour_Name))))
Player_Info <- merge(Player_Info,Common_Tour, by = c("Player_ID"))
Weight_Sums <- summarise(Player_ID_Group,
                         Weight_Sum = sum(Weight),Center_Wt = (sum(Weight*Week_Delta)/sum(Weight)))
Weight_Sums$Center_Wt <- (Exponential_Decay_Constant ^ (Weight_Sums$Center_Wt))/Max_Weight*10
Player_Info <- merge(Player_Info,Weight_Sums, by = c("Player_ID"))
remove(Common_Tour)
remove(Weight_Sums)
remove(Player_ID_Group)

# Find out most recent info

# Recent Tour
Player_Info_2 <-   subset(Player_Info, Tour_Name != "Major Championship" & 
                            Tour_Name != "WGC" & 
                            Event_Date >= as.Date(Rating_Date - 365) &
                            Event_Date <= as.Date(Rating_Date + 365))
Player_Info_2$Recent_Tour_Wt <- 0.90^Player_Info_2$Week_Delta 


Player_ID_Group <- group_by(Player_Info_2,Player_Name,Player_ID,Tour_Name)
Recent_Tour <- summarise(Player_ID_Group,
                         Tour_Wt = sum(Recent_Tour_Wt)) %>%
  filter(Tour_Wt == max(Tour_Wt)) %>% 
  rename(Recent_Tour=Tour_Name) %>%
  select(Player_ID,Recent_Tour)

Recent_Tour$Player_Name <- NULL


Player_Info <- merge(Player_Info,Recent_Tour, by = c("Player_ID"), all.x=TRUE)

remove(Player_Info_2)
remove(Recent_Tour)
remove(Player_ID_Group)



Player_Info <- subset(Player_Info, select = -c(Tour_Name,Weight,Event_Date,Week_Delta))
Player_Info <- Player_Info[!duplicated(Player_Info$Player_ID),]
Player_Info$Recent_Tour[is.na(Player_Info$Recent_Tour)] <- "None"
Player_Info$Recent_Tour[Player_Info$Rounds_Last_Year<17] <- "None"

str(Player_Info)





### Call Regression and Clean Up Results ####

BigLM_Fit_Results <- BigLM_Golf_Regression (Target_Subset)


library(broom)
Target_Results <- tidy(BigLM_Fit_Results)
Target_Results_Rounds <-
  Target_Results[grep("Round_ID",Target_Results$term),]
Target_Results_Players <-
  Target_Results[grep("Player_ID",Target_Results$term),]
Target_Results_Rounds$Round_ID <-
  as.factor((gsub("^.*ID","",Target_Results_Rounds$term)))
Target_Results_Players$Player_ID <-
  as.factor((gsub("^.*ID","",Target_Results_Players$term)))

Intercept_Results <- Target_Results[1,2]



Target_Results_Players <-
  merge(Target_Results_Players,Player_Info,by = c("Player_ID"))
Target_Results_Players <-
  Target_Results_Players[setdiff(names(Target_Results_Players), "term")]




### Section calculating and incorporating standard deviations ####


Center_Estimates <- function (Data){
  Primary_Players <- Data[Data$Primary_Player==1,]
  Avg_estimate <- mean(Primary_Players$estimate)
  Data$estimate <- Data$estimate-Avg_estimate
  return (Data)
}

Target_Results_Players <- Center_Estimates(Target_Results_Players)







Target_Subset <-
  merge(Target_Subset,Target_Results_Players[,c("Player_ID","estimate")], by = c("Player_ID"))
names(Target_Subset)[names(Target_Subset) == "estimate"] <-
  "Player_Est"

Target_Subset <-
  merge(Target_Subset,Target_Results_Rounds[,c("Round_ID","estimate")], by = c("Round_ID"))
names(Target_Subset)[names(Target_Subset) == "estimate"] <-
  "Round_Est"

Target_Subset$Predicted_Score <-
  Target_Subset$Player_Est + Target_Subset$Round_Est + Intercept_Results
Target_Subset$Residual <-
  Target_Subset$Score - Target_Subset$Predicted_Score



library(Hmisc)
library(dplyr)
Player_ID_Group <- group_by(Target_Subset,Player_ID)

Stdevs <- summarise(Player_ID_Group,
                    Sample_Stdev = sqrt(wtd.var(Residual,Weight *
                                                  10000000)))
Target_Results_Players <-
  merge(Target_Results_Players,Stdevs, by = c("Player_ID"))



Round_ID_Group <- group_by(Target_Subset,Round_ID)

Round_Strength <- summarise(Round_ID_Group,
                            Avg_Player = mean(Player_Est))

Target_Subset_2 <- merge(Target_Subset,Round_Strength, by = c("Round_ID"))

Player_ID_Group_2 <- group_by(Target_Subset_2,Player_ID)
Avg_Round_SoS <- summarise(Player_ID_Group_2,
                           Avg_SoS = wtd.mean(Avg_Player,Weight * 1000000))

Target_Results_Players <-
  merge(Target_Results_Players,Avg_Round_SoS, by = c("Player_ID"))


remove(Player_ID_Group, Round_ID_Group,Player_ID_Group_2,Target_Subset_2)




### Post_Processing ####


Projection <- function (Data) {
  
  library(dplyr)
  
  # Create 2 Bayesian Priors, one based on average tournament entered, other based on overall player distribution
  # Weight the first by a constant + recency of tournaments * coefficient

  Prior_Tournaments_wt_Const <- 2.0                     # Constant weight
  Prior_Tournaments_wt_Time_Ago <- 0.0                  # Time ago weight
  Prior_Tournaments_wt_Time_Ago_x_Total <- 0.05         # (Time ago * Total observations wt)
  Prior_Tournaments_wt_sqrt_Time_Ago_x_Total <- 0.0     # sqrt(Time ago * Total observations wt)
  
  Prior_Tournaments_Stderr <- 7.0
  
  
  Prior_Players_wt_const <- 1.5
  Prior_Players_Value <- 8.0
  Prior_Players_Stderr <- 0.0
  
  Prior_Stdev_value <- 2.75
  Prior_Stdev_wt_const <- 115
  
  Data$Prior_Tournament_SoS_Weight <-  (Prior_Tournaments_wt_Const 
                                   + Prior_Tournaments_wt_Time_Ago * Data$Center_Wt
                                   + Prior_Tournaments_wt_Time_Ago_x_Total * (Data$Center_Wt * Data$Weight_Sum)
                                   + Prior_Tournaments_wt_sqrt_Time_Ago_x_Total * sqrt(Data$Center_Wt * Data$Weight_Sum))
  
  Data$Total_Weight <-
    (Data$Weight_Sum 
     +  Data$Prior_Tournament_SoS_Weight
     +  Prior_Players_wt_const
    )  
  
  Data$Projected_Rating <-
    (
      (Data$estimate * Data$Weight_Sum 
       + Data$Avg_SoS * Data$Prior_Tournament_SoS_Weight
       + Prior_Players_Value * Prior_Players_wt_const
       ) / 
        Data$Total_Weight
    )
  
  
  Data$Expected_Stdev <-
    (Data$Sample_Stdev * Data$Weight_Sum + Prior_Stdev_value * Prior_Stdev_wt_const) / (Data$Weight_Sum +
                                                                                          Prior_Stdev_wt_const)
  
  # Generate a forward standard error
  
  Data$Rating_StdErr <- sqrt(
    (Prior_Players_wt_const/Data$Total_Weight)^2*(Prior_Players_Stderr)^2
    + (Data$Prior_Tournament_SoS_Weight/Data$Total_Weight)^2*(Prior_Tournaments_Stderr)^2
    + (Data$Weight_Sum/Data$Total_Weight)^2*(Data$std.error)^2
      )
  
  Data$Projected_Stdev <- sqrt(Data$Expected_Stdev^2 + Data$Rating_StdErr^2)
  
  return (Data)
}

Target_Results_Players<- Projection(Target_Results_Players)

Target_Results_Players$Rank <- rank(Target_Results_Players$Projected_Rating)




###  Get Previous Ratings and show delta ####

Prev_Results_Available <- ifelse(file.exists(Previous_Ratings),TRUE,FALSE)

if(Prev_Results_Available) {Previous_Target_Results <- read.csv(file = Previous_Ratings)

Previous_Target_Results <- Previous_Target_Results[,c("Player_ID","Projected_Rating","Rank")]

names(Previous_Target_Results)[names(Previous_Target_Results) == "Projected_Rating"] <-
  "Previous_Rating"

names(Previous_Target_Results)[names(Previous_Target_Results) == "Rank"] <-
  "Prev_Rank"

Target_Results_Players <-
  merge(Target_Results_Players,Previous_Target_Results, by = c("Player_ID"), all.x = TRUE)

Target_Results_Players$Change <- Target_Results_Players$Projected_Rating - Target_Results_Players$Previous_Rating
Target_Results_Players$Rank_Change <- Target_Results_Players$Rank - Target_Results_Players$Prev_Rank
}


###  Import OWGR Ratings

OWGR_Players <- read.csv(("Data/Player_OWGR_History.csv")) %>%
  mutate(Date = as.Date(OWGR_Rank_Date)) %>%
  filter(Date < Rating_Date, Date > Prev_Rating_Date)

Target_Results_Players <- merge(Target_Results_Players,OWGR_Players[c("Player_ID","OWGR_Rank")],all.x = TRUE)


### Rearrange and export results ####

Target_Results_Players$Rating_Date <- Rating_Date

if(Prev_Results_Available) {Target_Results_Players <-
  Target_Results_Players[,c("Rank",
                            "OWGR_Rank",
                            "Player_Name",
                            "Player_ID",
                            "Projected_Rating",
                            "Rating_StdErr",
                            "Projected_Stdev",
                            "Prev_Rank",
                            "Rank_Change",
                            "Previous_Rating",
                            "Change",
                            "Weight_Sum",
                            "Total_Weight",
                            "Rounds_Player",
                            "Avg_SoS",
                            "Center_Wt",
                            # "Player_Avg_OWGR_Pts",
                            "Primary_Player",
                            "Country",
                            "Rounds_Last_Year",
                            "Recent_Tour",
                            "Common_Tour",
                            "estimate",
                            "std.error",
                            "p.value",
                            "Sample_Stdev",
                            "Expected_Stdev",
                            "Rating_Date"
  )]} else {
    Target_Results_Players <-
      Target_Results_Players[,c("Rank",
                                "OWGR_Rank",
                                "Player_Name",
                                "Player_ID",
                                "Projected_Rating",
                                "Rating_StdErr",
                                "Projected_Stdev",
                                "Weight_Sum",
                                "Total_Weight",
                                "Rounds_Player",
                                "Avg_SoS",
                                "Center_Wt",
                                # "Player_Avg_OWGR_Pts",
                                "Primary_Player",
                                "Country",
                                "Rounds_Last_Year",
                                "Recent_Tour",
                                "Common_Tour",
                                "estimate",
                                "std.error",
                                "p.value",
                                "Sample_Stdev",
                                "Expected_Stdev",
                                "Rating_Date"
      )]
    
    
  }






Target_Results_Players <-
  Target_Results_Players[order(Target_Results_Players$Rank),]


write.csv(Target_Results_Players, file = Save_Location, row.names = FALSE)

Current_Rating_Date <- Sys.Date() + (4 - wday(Sys.Date()))   # Wednesday of the current week

if (Rating_Date == Current_Rating_Date) {
  Save_Location_Current <-
    "Output/Golf_Ratings_Current.csv"
  
  Save_Location_Web_Table <-
    "Output/Golf_Ratings_Current_Web_Table.csv"
  
  if(Prev_Results_Available){Website_Results_Table <-
    Target_Results_Players[,c("Rank",
                              "OWGR_Rank",
                              "Player_Name",
                              "Projected_Rating",
                              "Projected_Stdev",
                              "Prev_Rank",
                              "Rank_Change",
                              "Previous_Rating",
                              "Change",
                              "Rounds_Last_Year",
                              "Recent_Tour"
    )] } else{
      Website_Results_Table <-
        Target_Results_Players[,c("Rank",
                                  "OWGR_Rank",
                                  "Player_Name",
                                  "Projected_Rating",
                                  "Projected_Stdev",
                                  "Rounds_Last_Year",
                                  "Recent_Tour"
        )] 
    }
  
  write.csv(Target_Results_Players, file = Save_Location_Current, row.names = FALSE)
  
  write.csv(Website_Results_Table, file = Save_Location_Web_Table, row.names = FALSE) 
  
}

# write.csv(Target_Subset, file = "~/ETC/Sports/Golf/Target_Subset_Before_2010_0.98.csv" , row.names = FALSE)
}



