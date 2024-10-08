#### IMPORT LIBRARIES ####
library(tidyverse)
library(tidymodels)
library(patchwork)
library(vroom)
library(poissonreg)
library(tidymodels)
library(glmnet)
library(stacks)

#
#### READ IN DATA ####
# read in train & test datasets with vroom()
train = vroom(file = "train.csv")
test = vroom(file = "test.csv")

#
#### EXPLORATORY DATA ANALYSIS ####
glimpse(train)

# Scatterplot of count over time
time_plot = ggplot(data = train, mapping = aes(x = datetime, y = count)) +
  geom_point() +
  geom_smooth(se = F)

# Scatterplot of count x temperature
temp_plot = ggplot(data = train, mapping = aes(x = temp, y = count)) +
  geom_point() +
  geom_smooth(se = F)

# Barplot of weather
weather_plot = ggplot(data = train, mapping = aes(x = weather)) +
  geom_bar()

# Scatterplot of count x humidity
humid_plot = ggplot(data = train, mapping = aes(x = humidity, y = count)) +
  geom_point() +
  geom_smooth(se = F)


# create a 4 panel ggplot (patchwork) showing 4 key features of the dataset
  # one panel must be a barplot of weather
(temp_plot + time_plot) / (humid_plot + weather_plot)



#### DATA CLEANING ####
train_clean = train %>% 
  select(-casual, -registered) %>% 
  mutate(count = log(count))

#### FEATURE ENGINEERING ####
# Create and "bake" the recipe
bike_recipe = recipe(count~., data=train_clean) %>% 
  step_mutate(weather = ifelse(weather==4,3,weather)) %>%   # recode 4 to 3
  step_mutate(weather = factor(weather, levels=c(1,2,3),    # factor season
                               labels=c("clear", "mist", "precipitation"))) %>% 
  step_time(datetime, features="hour") %>%                  # extract hour
  step_mutate(datetime_hour = factor(datetime_hour,         # factor hour
                                     levels=c(0:23), labels=c(0:23))) %>% 
  step_mutate(season = factor(season, levels=c(1,2,3,4),    # factor weather
                              labels=c("spring", "summer", "fall", "winter"))) %>% 
  step_date(datetime, features="dow") %>%                   # extract day of week
  step_interact(terms = ~ datetime_hour*workingday) %>% 
  step_date(datetime, features="year") %>%                  # make year a variable
  step_rm(datetime) %>%
  step_dummy(all_nominal_predictors()) %>%                  # make dummy variables
  step_normalize(all_numeric_predictors()) %>%              # mean = 0, sd = 1
  step_corr(all_predictors())

prepped_recipe = prep(bike_recipe)
bike_baked = bake(prepped_recipe, new_data=train_clean)

## BART ####
bart_model <- parsnip::bart(
  mode = "regression",
  engine = "dbarts",
  trees = 1000,
  prior_terminal_node_coef = .95,
  prior_terminal_node_expo = 2,
  prior_outcome_range = 2)

bart_wf <- workflow() %>% 
  add_recipe(bike_recipe) %>% 
  add_model(bart_model) %>% 
  fit(data = train_clean)

## CV ####
# Grid of values to tune over
grid_of_tuning_params <- grid_regular(min_n(),
                                      levels = 5) ## L^2 total tuning possibilities

## Split data for CV
folds <- vfold_cv(train_clean, v = 3, repeats=1)

# Run the CV1
CV_results <- bart_wf %>%
  tune_grid(resamples=folds,
            grid=grid_of_tuning_params,
            metrics=NULL) #Or leave metrics NULL

# Find Best Tuning Parameters
bestTune <- CV_results %>%
  select_best(metric="rmse")

## Finalize the Workflow & fit it ####
final_wf <- bart_wf %>%
  finalize_workflow(bestTune) %>%
  fit(data=train_clean)


#####
## MAKE PREDICTIONS ##
## Predict
bart_wf %>%
  predict(new_data = test)
knn_preds = predict(bart_wf, new_data = test)

## Format predictions for kaggle submission
recipe_kaggle_submission <- knn_preds %>% 
  bind_cols(., test) %>% 
  select(datetime, .pred) %>% 
  rename(count = .pred) %>% 
  mutate(datetime=as.character(format(datetime))) %>% 
  mutate(count = exp(count))

## Write out file
vroom_write(x=recipe_kaggle_submission, file="./KNNPreds.csv", delim=",")


