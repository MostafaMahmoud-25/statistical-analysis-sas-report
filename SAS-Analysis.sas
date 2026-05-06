%web_drop_table(WORK.IMPORT);


FILENAME REFFILE '/home/u64499790/ecommerce_users.csv';

PROC IMPORT DATAFILE=REFFILE
	DBMS=CSV
	OUT=WORK.IMPORT;
	GETNAMES=YES;
RUN;

%web_open_table(WORK.IMPORT);

/*EDAAAAAAAAAAAAA*/
/* --- 1. DATA INVENTORY & TYPES --- */
proc contents data=WORK.IMPORT;
    title "Data Audit: Variable Types and Storage";
run;

/* --- 2. THE NULL VALUE HUNT --- */
title "Data Audit: Missing Values (Numerical)";
proc means data=WORK.IMPORT n nmiss mean std min max;
    var _numeric_;
run;

/* --- 3. CATEGORICAL GAPS --- */
title "Data Audit: Frequency & Missingness (Categorical)";
proc freq data=WORK.IMPORT;
    tables gender device_type / missing;
run;

/* --- 4. THE DUPLICATE CHECK --- */
/* This checks if any rows are 100% identical and puts them in 'DUPE_LIST'. */
proc sort data=WORK.IMPORT 
          out=CLEAN_TEMP 
          noduprecs 
          dupout=DUPE_LIST;
    by _all_;
run;

title "Data Audit: List of Duplicate Rows";
proc print data=DUPE_LIST;
run;

/* --- 5. DATA ANOMALY DETECTION --- */
title "Data Audit: Extreme Observations & Outliers";
proc univariate data=WORK.IMPORT;
    var age time_on_site bounce_rate;
  run;  
  
  
ods graphics on;

    title "Visual 1: Distribution of the Target Variable (Purchase)";
proc sgplot data=WORK.IMPORT;
    /* The /missing option shows the 160 'ghost' rows as a bar */
    vbar purchase / missing datalabel stat=percent fillattrs=(color=CX3A86FF);
    xaxis label="Purchase Status (0=No, 1=Yes, Missing=Null)";
    yaxis label="Percentage of Total Data";
run;
title;


title "Visual 2: Browsing Behavior vs. Purchase Decision";
proc sgplot data=WORK.IMPORT;
    /* This handles the 8,000 rows by summarizing them into boxes */
    vbox pages_viewed / category=purchase 
         fillattrs=(color=CXFFB703) 
         lineattrs=(color=black thickness=2);
    xaxis label="Did they buy? (0=No, 1=Yes)";
    yaxis label="Number of Pages Viewed";
run;
title; /* Clears the title for future steps */

/* CLEANINGGGGG*/
/* Null Handling*/
data WORK.ECOM_CLEAN;
    set WORK.IMPORT; /* Ensure this is 'IMPORT' or whatever your raw set is named */
    
    /* A. Nuke the 'Ghost' rows */
    if missing(purchase) then delete;
    if missing(user_id) then delete; /* Keep the ID as a primary guard */

    /* B. The Dot Killer: Impute zeros for metrics so math doesn't break */
    if missing(time_on_site) then time_on_site = 0;
    if missing(pages_viewed) then pages_viewed = 0;
    if missing(cart_items) then cart_items = 0;
    if missing(previous_purchases) then previous_purchases = 0;
    if missing(avg_session_time) then avg_session_time = 0;
    if missing(ad_clicked) then ad_clicked = 0;
run;


/* 2. DEDUPLICATION */
proc sort data=WORK.ECOM_CLEAN out=WORK.ECOM_CLEAN noduprecs;
    by _all_;
run;



/* --- VISUAL 3: THE IMPACT OF DATA CLEANING --- */
/* This table reflects the reality of the 160 rows we purged */
data cleaning_stats;
    length Stage $10;
    input Stage $ Count;
    datalines;
Original 8000
Cleaned  7840
;
run;

title "Visual 3: Impact of Data Cleaning (Rows Removed)";
proc sgplot data=cleaning_stats;
  
    vbar Stage / response=Count 
                stat=sum 
                fillattrs=(color=CXE63946) 
                datalabel;
    yaxis label="Total Observations" grid;
    xaxis label="Project Stage";
run;

/* 1. Create a format to turn 0/1 into words */
proc format;
    value purcfmt
        0 = "Didn't Purchase"
        1 = "Purchased";
run;

title "Visual 4: Purchase Distribution Analysis";
proc gchart data=WORK.ECOM_CLEAN;
    /* We apply the format here so the words appear on the chart */
    format purchase purcfmt.;
    
    pie purchase / discrete 
                   type=percent 
                   percent=arrow
                   slice=outside
                   value=none;
run;
quit;

/* Feature Engineeringgggg*/
data WORK.ECOM_FEATURES;
    set WORK.ECOM_CLEAN;

    /* 1. Browsing Velocity (Pages viewed per minute) */
    if time_on_site > 0 then velocity = pages_viewed / time_on_site;
    else velocity = 0;

    /* 2. Purchase Intensity (How 'full' was their browsing?) */
    if pages_viewed > 0 then cart_density = cart_items / pages_viewed;
    else cart_density = 0;

    /* 3. The VIP Client Flag (Returning + Previous Purchase history) */
    if returning_user = 1 and previous_purchases > 0 then vip_client = 1;
    else vip_client = 0;

    /* 4. Decision Time (How long they spend thinking per item) */
    if cart_items > 0 then time_per_item = time_on_site / cart_items;
    else time_per_item = 0;

    /* Adding Labels so the Modeler knows what they are looking at */
    label velocity = "Pages per Minute"
          cart_density = "Items per Page Viewed"
          vip_client = "Loyal High-Value User"
          time_per_item = "Minutes per Cart Item";
run;

/* Final Verification: The 4 Features + User ID */
title "Feature Engineering Audit: The Big Four Model Inputs";
proc print data=WORK.ECOM_FEATURES (obs=10);
    var user_id velocity cart_density vip_client time_per_item;
run;

/* A Histogram shows if most people are 'Fast' or 'Slow' shoppers */
title "Visual 5: Distribution of Browsing Velocity";
proc sgplot data=WORK.ECOM_FEATURES;
    histogram velocity / fillattrs=(color=CX457B9D) transparency=0.3;
    density velocity; /* Adds a smooth trend line */
    xaxis label="Browsing Speed (Pages per Minute)";
    yaxis label="Frequency of Users";
run;

/* A Grouped Bar Chart to show the VIP impact on Purchases */
title "Visual 6: VIP Status vs. Final Purchase Rate";
proc sgplot data=WORK.ECOM_FEATURES;
    vbar vip_client / group=purchase 
                      groupdisplay=cluster 
                      fillattrs=(transparency=0.2)
                      datalabel;
    xaxis label="VIP Client Status (0 = Regular, 1 = VIP)";
    yaxis label="Number of Users";
    keylegend / title="Purchased?";
run;

/*Model Buildinggggggg*/
title "Binary Logistic Regression Model";
/* --- STEP 1: THE DATA SPLIT (70% Training / 30% Testing) --- */
proc surveyselect data=WORK.ECOM_FEATURES out=WORK.ECOM_SPLIT 
                  seed=12345 method=srs samprate=0.7 outall;
run;

/* --- STEP 2: THE PREDICTIVE MODEL --- */
title "Binary Logistic Regression: Predicting Purchase Intent";
proc logistic data=WORK.ECOM_SPLIT descending;
    where selected = 1;
    
    model purchase = velocity cart_density vip_client time_per_item / stb;
    
    /* Save the 'Probability Scores' for every user */
    score data=WORK.ECOM_SPLIT(where=(selected=0)) out=WORK.TEST_RESULTS;
run;
    
/* 1. Create a Character Format for the predicted variable */
proc format;
    value $purc_char
        "0" = "Didn't Purchase"
        "1" = "Purchased";
run;

/*VALIDATIONNN*/
title "Model Validation: Full Accuracy & Prediction Audit";
proc freq data=WORK.TEST_RESULTS;
    tables purchase * I_purchase / chisq kappa senspec nocol norow nopercent;
    
    /* We use the numeric format for 'purchase' and the $ format for 'I_purchase' */
    format purchase purcfmt. I_purchase $purc_char.;
run;

/* --- FINAL PERFORMANCE SCORECARD --- */
title "Executive Summary: Accuracy, Precision, and Recall";
ods select Classification; 
proc logistic data=WORK.TEST_RESULTS descending;
    model purchase = P_1 / ctable pprob=0.5;
run;
ods select all;



/* 1. Capture the math table into a dataset for plotting */
title "Getting Dataset Ready for visuals";
ods output ParameterEstimates=WORK.FINAL_RANKING;
proc logistic data=WORK.ECOM_SPLIT descending;
    where selected = 1;
    model purchase = velocity cart_density vip_client time_per_item / stb;
run;


/* 2. Plot the Standardized weights */
proc sgplot data=WORK.FINAL_RANKING;
    title "Visual 7: Feature Power Ranking - Which Metric Drives Sales?";
    where Variable ne "Intercept";
    hbar Variable / response=StandardizedEst 
         fillattrs=(color=CX1D3557) 
         categoryorder=respdesc 
         datalabel;
    xaxis label="Standardized Prediction Strength (Relative Impact)";
    yaxis label="Engineered behavioral Metric";
run;

title "Visual 8: Probability Distribution - Predicted vs. Actual";

proc sgplot data=WORK.TEST_RESULTS;
    /* We plot the Actual Outcome (0 or 1) vs. the Predicted Probability (0 to 1) */
    /* JITTER spreads the points out so you can see the density */
    scatter x=purchase y=P_1 / 
            jitter 
            transparency=0.6 
            markerattrs=(symbol=CircleFilled size=8 color=CXE63946);

    /* A reference line at 0.5 shows the 'Decision Boundary' */
    refline 0.5 / axis=y lineattrs=(thickness=2 color=gray pattern=shortdash);

    yaxis label="Model Confidence Score (0.0 to 1.0)" values=(0 to 1 by 0.1);
    xaxis label="Actual Outcome (0 = No Purchase, 1 = Purchase)" values=(0, 1);
run;
