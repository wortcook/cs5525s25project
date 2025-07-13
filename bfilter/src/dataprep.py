#!/usr/bin/env python3
import pandas as pd
from sklearn.naive_bayes import MultinomialNB

from sklearn.feature_extraction.text import CountVectorizer
# from sklearn.feature_extraction.text import HashingVectorizer
# from sklearn.feature_extraction.text import TfidfVectorizer

import joblib
import hashlib
import datetime
import os


#STARTUP CHECK, HAVE THE ENVIRONMENT VARIABLES BEEN SET
LLMSTUB_URL = os.getenv("LLMSTUB_URL")
if not LLMSTUB_URL:
    raise ValueError("LLMSTUB_URL environment variable is not set.")

# SECONDARYSTUB_URL = os.getenv("SECONDARYSTUB_URL")
# if not SECONDARYSTUB_URL:
#     raise ValueError("SECONDARYSTUB_URL environment variable is not set.")

def process_text(text: str) -> list[str]:
    #Break into words
    words = text.split(" ")
    for word in words:
        #Remove words that are less than 3 characters
        if len(word) == 1:
            words.remove(word)
        else:
            #Remove all vowels
            word = word.replace("aeiou", "")
            #Remove all numbers
            word = word.replace("0123456789", "")
        
    #Rejoin the words
    text = " ".join(words)
    
    #reverse the text
    textReversed = text[::-1]
    
    #Save the text
    return [text, textReversed]

####################
# Vectorize and model builder
# Simple process to load the dataset, vectorize it, and train a model
# then save the vectors and model to disk as part of the docker image


####################
# Notes to future self:
# - This is the same as exp003 except we dump the model and vectorizer to disk
# - Scale will be a problem as the dataset grows, could incremental training help?
#


####################
# Dataset load
dataset = pd.read_csv("jailbreaks.csv")

dataset["text"] = dataset["text"].str.lower()

reversedText = []

####################
#Loop through dataset text
for i in range(len(dataset["text"])):
    #Get the text
    textProcessed = process_text(dataset["text"][i])
    dataset.loc[i, "text"] = textProcessed[0]
    reversedText.append(textProcessed[1])
    
#Add the reversed text to the dataset
dataset["text"] = dataset["text"] + pd.Series(reversedText)

####################
# Vectorize
cv = CountVectorizer()
# cv = HashingVectorizer()
# cv = TfidfVectorizer()
X = cv.fit_transform(dataset["text"])


####################
# Train
clf = MultinomialNB()
clf.fit(X, dataset["class"])

####################
# Save
joblib.dump(clf, "model.pkl")
joblib.dump(cv, "cv.pkl")

####################
# Calculate the hash of the model.pkl and cv.pkl files
# to see if they have changed
modelHash = hashlib.md5(open("model.pkl","rb").read()).hexdigest()
sourceHash = hashlib.md5(open("server.py","rb").read()).hexdigest()
timehash = hashlib.md5(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S").encode("utf-8")).hexdigest()
thishash = hashlib.md5(open(__file__,"rb").read()).hexdigest()

deployHash = hashlib.md5((modelHash + sourceHash + thishash + timehash).encode("utf-8")).hexdigest()

joblib.dump(deployHash, "deployHash.txt")
