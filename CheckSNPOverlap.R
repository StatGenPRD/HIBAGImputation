######################################################################################################
#
# CheckSNPOverlap.R
# Author: Judong Shen (judong.x.shen@gsk.com)
#
######################################################################################################

# overlap.check: checking the SNPs includes in the GWAS data and those included in all classifiers
# Make sure the GWAS data is on hg19/GRCh37, subset to xMHC (chr6:25651242-33544122) and has unique marker names
overlap.check <- function(in.data, classifier.loc, ancestry.file){
  #Get markers in data from bim file
  bim.file <- paste(in.data, "bim",sep=".")
  bim.d <- read.table(bim.file,na.strings = c("",".",NA),check.name=FALSE,as.is=T, head=F, sep="")
  
  #Read ancestry file
  ancestry <- read.table(ancestry.file,header=TRUE,stringsAsFactors=FALSE)
  a.groups <- unique(ancestry$Ethnicity)
  
  #Determine relevant classifiers (4-digit resolution, hg19, ancestry groups present in data)
  classifiers <- list.files(classifier.loc)
  classifiers <- classifiers[grep("-HLA4-hg19.RData", classifiers)]
  classifiers <- classifiers[grep(paste(a.groups,collapse="|"), classifiers, perl=TRUE)]
  
  #Initialize results from assessing model fit
  out <- NULL
  
  for (classifier in classifiers){
    #echo classifier for monitoring progress
    cat(classifier, "\n")

    #Load classifier
    model.list <- get(load(paste(classifier.loc, classifier,sep="/")))
    #Parse classifier filename to get details
    classifier1 <- gsub("-HLA4-hg19.RData","",classifier)
    classifier1 <- unlist(strsplit(classifier1,"-"))

    #Initialize vector to store names of markers with matching alleles
    overlap.id.am = c()

    for (hla.id in c("A", "B", "C", "DRB1", "DQA1", "DQB1", "DPB1")){
      #Load model for locus
      model <- hlaModelFromObj(model.list[[hla.id]])
      #Summarize model
      perf <- summary(model,show=FALSE)

      #Determine positions of markers in model
      #Some markers in model are not used in any of classifiers so can't use model's top-level snp vectors
      model.snp.pos <- perf$snp.position[perf$snp.hist > 0]
      model.snp.hist <- perf$snp.hist[perf$snp.hist > 0]
      #Determine positions in both model and data
      overlap.pos <- intersect(bim.d$V4,model.snp.pos)
      #Initialize vector to store positions of markers with matching alleles
      overlap.pos.am = c()   

      #For each marker in data
      for (i in 1:nrow(bim.d)) {
        #If marker position also in model
        if (bim.d$V4[i] %in% overlap.pos) {
          #Determine model alleles
          model.alleles <- sort(unlist(strsplit(model$snp.allele[model$snp.position == bim.d$V4[i]],'/')))
          #If model alleles non-ambiguous
          #HIBAG is not resolved to any strand - it uses strand of training data which was Illumina and thus unresolved
          #HIBAG will attempt to match these by frequency which is unreliable
          #There is no option to control this behavior so treating as allele-mismatches here
          if (!(all(model.alleles == c("C","G")) || all(model.alleles == c("A","T")))) {
            #Determine alleles in data
            bim.alleles <- sort(c(bim.d$V5[i], bim.d$V6[i]))
            #Determine alleles in data if strand opposite model
            bim.alleles.flip <- sort(c(switch(bim.d$V5[i], "C" = "G", "G" = "C", "A" = "T", "T" = "A", "0" = "0", ""),switch(bim.d$V6[i], "C" = "G", "G" = "C", "A" = "T", "T" = "A", "0" = "0", "")))
            #If data alleles match model track ID and position
            if (all(bim.alleles == model.alleles) || 
              all(bim.alleles.flip == model.alleles) || 
              (bim.alleles[1] == "0" && bim.alleles[2] %in% model.alleles) ||
              (bim.alleles.flip[1] == "0" && bim.alleles.flip[2] %in% model.alleles) ) {
              overlap.id.am <- c(overlap.id.am,bim.d$V2[i]);
              overlap.pos.am <- c(overlap.pos.am,bim.d$V4[i]);
            }
          }
        }
      }
      #Create dataframe of positions of markers in model and count of how many classifiers each marker is in
      #Using latter as measure of importance of marker
      perf.df <- cbind(data.frame(model.snp.pos,model.snp.hist))
      #Add another column to the dataframe with percentile of marker's contribution to classifier
      perf.df <- within(perf.df, snp.hist.pctl <- rank(model.snp.hist)/length(model.snp.hist))
      #Subset to markers missing from data
      perf.df.missing <- perf.df[!perf.df$model.snp.pos %in% overlap.pos.am,]

      #Append results to out dataframe
      out <- rbind(out, data.frame(classifier = classifier, Assay = classifier1[1], Ancestry = classifier1[2],
        HLA.locus = model$hla.locus, model.platform = model$appendix$platform, 
        num.classifier = perf$num.classifier, num.model.snp = length(model.snp.pos),
        mean.snp.in.classif = perf$info$Mean[1], mean.haplo.in.classif = perf$info$Mean[2], mean.accuracy = perf$info$Mean[3],
        num.model.in.data = length(overlap.pos.am), pct.model.in.data = length(overlap.pos.am) / length(model.snp.pos),
        sum.miss.pctl = sum(perf.df.missing$snp.hist.pctl)))

      #Close model to reclaim memory
      hlaClose(model)
    }

    #Write names of markers with matching alleles for this classifier in case selected as best
    write(unique(overlap.id.am), file=paste("./Results_CheckSNPOverlap/",classifier,".extract.IDs.txt",sep=""), ncolumns=1)
  }

#Write results of assessing model fits
write.table(out, file = "./Results_CheckSNPOverlap/comparison.txt",row.names=FALSE, sep = "\t")

#return results of assessing model fits
out
}


# select.best: select best classifier for each ancestry group and locus
select.best <- function(details) {
  #Initialize best
  best <- NULL

  #Determine optimal classifier for each locus and ancestry group
  for (hla.id in c("A", "B", "C", "DRB1", "DQA1", "DQB1", "DPB1")) {
    for (ancestry in unique(details$Ancestry)) {
      #Subset details to locus & ancestry
      sub.details <- details[details$Ancestry == ancestry & details$HLA.locus == hla.id,]
      #Calculate rank by summing rank over accuracy and sum of missing markers' contribution to classifiers
      sub.details <- within(sub.details, raw.rank <- rank(-sub.details$mean.accuracy) +
        rank(sub.details$sum.miss.pctl))
      #Subset to best rank
      best.details <- sub.details[sub.details$raw.rank == min(sub.details$raw.rank),]
      #Pick best of multiple using pct.overlap
      best.classif <- best.details[best.details$pct.model.in.data == max(best.details$pct.model.in.data),]$classifier
      #Append results to best dataframe
      best <- rbind(best, data.frame(Ancestry = ancestry, HLA.locus = hla.id, Classifier = best.classif))
    }
  }

  #Write results of optimal selection
  write.table(best, file="./Results_CheckSNPOverlap/SelectedClassifiers.txt",row.names=FALSE, sep = "\t")

}

library(HIBAG)

myargs = commandArgs(TRUE)
#check all arguments specified
if (length(myargs) < 2) {
  cat("Invalid arguments, should be: \"--args [root of plink dataset] [ancestry file] \"\n")
  q()
}
in.data <- myargs[1]
race.file <- myargs[2]
classifier.loc <- "/GWD/appbase/projects/RD-MDD-GX_PUBLIC/HIBAG_Classifiers"

overlap.res <- overlap.check(in.data=in.data, classifier.loc=classifier.loc, ancestry.file=race.file)
select.best(details=overlap.res)

