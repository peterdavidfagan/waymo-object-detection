.PHONY: run-streamlit run-streamlit-container-locally gcloud-deploy-streamlit \
		gcloud-deploy-prediction-application gcloud-tear-down-prediction-web-application \
		gcloud-run-waymo-data-processing gcloud-train-job \
		gcloud-train-sweep gcloud-deploy-app



run-streamlit-container-locally:
	@docker build herbie_vision/streamlit_app/. -t herbie_vision
	@docker run -p 8080:8080 --cap-add SYS_ADMIN --device /dev/fuse herbie_vision


gcloud-deploy-prediction-application:
	@gcloud container clusters create prediction --flags-file ./config/model_serving/cluster_config.yaml
	@gcloud container clusters get-credentials prediction --zone us-central1-a --project waymo-2d-object-detection
	@kubectl apply -f ./config/model_serving/persistent_volume.yaml
	@kubectl apply -f ./config/model_serving/persistent_volume_claim.yaml
	@kubectl apply -f ./config/model_serving/kubernetes_deployment.yaml
	@kubectl expose deployment prediction --type=LoadBalancer --name=prediction-service --port 80 --target-port 5000
	@echo 'Wating for external ip to be initialized...'
	@sleep 60
	@kubectl get services
	@sed -i .bak "s|.*REST_API.*|ENV REST_API=\"http://$$(kubectl get services prediction-service -o json | jq '.status.loadBalancer.ingress | to_entries | .[0].value.ip' | tr -d '"')/predict\"|" ./cs329s_waymo_object_detection/streamlit_app/Dockerfile

gcloud-deploy-app:
	@gcloud container clusters create streamlit --flags-file ./config/streamlit_deployment/cluster_config.yaml
	@gcloud container clusters get-credentials streamlit --zone us-central1-a --project waymo-2d-object-detection
	@kubectl apply -f ./config/streamlit_deployment/persistent_volume.yaml
	@kubectl apply -f ./config/streamlit_deployment/persistent_volume_claim.yaml
	@sleep 15
	@kubectl apply -f ./config/streamlit_deployment/kubernetes_deployment.yaml
	@kubectl expose deployment streamlitweb --type=LoadBalancer --name=my-service
	@sleep 60
	@kubectl get services



gcloud-tear-down-prediction-web-application:
	@gcloud container clusters delete streamlit --zone us-central1-c --quiet # automate zone flag in future
	@gcloud app services delete web-application --quiet


gcloud-waymo-data-processing:
	@gcloud compute instances create-with-container thor-train \
	 --machine-type e2-standard-8 --boot-disk-size 200 \
	 --container-image gcr.io/waymo-2d-object-detection/dataprocessing_train

	@gcloud compute instances create-with-container thor-test \
	--machine-type e2-standard-8 --boot-disk-size 200 \
	--container-image gcr.io/waymo-2d-object-detection/dataprocessing_test

	@gcloud compute instances create-with-container thor-validation \
	--machine-type e2-standard-8 --boot-disk-size 200 \
	--container-image gcr.io/waymo-2d-object-detection/dataprocessing_validation

gcloud-train-job:
	@gcloud compute instances create pytorch-cpu \
	  --zone=us-central1-c \
	  --image-family=pytorch-latest-cpu \
	  --image-project=deeplearning-platform-release \
	  --machine-type e2-standard-8 \
	  --accelerator="type=nvidia-tesla-t4,count=1" \
	  --boot-disk-size 100 \
	  --metadata-from-file startup-script=mount.sh
	@sleep 120
	@gcloud compute scp --recurse /Users/peterfagan/Code/herbie-vision/herbie_vision/model/model_training/ pytorch-cpu:/tmp
	@gcloud compute ssh pytorch-cpu --command "sudo mv /tmp/* /home/waymo"
	@gcloud compute ssh pytorch-cpu --command "pip3 install --upgrade pip setuptools wheel"
	@gcloud compute ssh pytorch-cpu --command "cd /home/waymo && pip3 install -r requirements.txt"
	@gcloud compute ssh pytorch-cpu --command "export WANDB_API_KEY=<> && \
											   cd /home/waymo && \
											   python3 train.py 'gcp_credentials.yaml' 'train.yaml'"
	@gcloud compute instances delete pytorch-cpu --quiet


gcloud-train-sweep:
	@gcloud container clusters create thor --flags-file ./config/model_training/cluster_config.yaml
	@gcloud container clusters get-credentials thor --zone us-central1-c --project waymo-2d-object-detection
	@kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded.yaml
	@kubectl apply -f ./config/model_training/wandb_kubernetes.yaml
	@kubectl create -f ./config/model_training/persistent_volume.yaml
	@kubectl create -f ./config/model_training/persistent_volume_claim.yaml
	@kubectl apply -f ./config/model_training/train_deployment.yaml
	@gcloud container clusters delete thor --zone us-central1-c --quiet # automate zone flag in future
