# Pacing-Fitness-Coach

Github: https://github.com/stonejinx/Pacing-Fitness-Coach.git

Project Draft

Idea: Create a product, which helps in training for running. The machine senses the heartbeat, temperature and speed / pace of the user. These sensor values are used to determine if the user needs to speed up or slow down to train.

Sensors to be used:
IMU - Accelerometer which senses speed / distance.
Heartbeat Sensing
Electrodermal Activity - to sense temp / sweating
Vibration IC

Algorithm for Decision Making:
It is appropriate to use a rule based algorithm to conduct decisions instead of machine learning. The idea is that the heartbeat and EDA will sense values which need to be held in certain thresholds for the user to train effectively. 

For example, if the machine senses that the BPM and temp are under nominal range, then it encourages the user to push their body and vice versa, if it is near or above the range, it alerts the user to slow down or pace themselves.

Literature Review
What % over Resting Heart Rate is acceptable? Should endurance zones be based on HRmax, resting HR, HRR (heart rate reserve), or personalized calibration?
Does acceptable range differ based on activities?
Accuracy of heartbeat/IMU sensor on wrist during motion
Can fatigue be inferred better using multimodal sensing instead of HR alone? (HRV, IMU cadence variability, Skin temperature, EDA (sweat proxy), Respiratory rate from motion)
How can we predict whether a runner will meet their goal before the run ends?
What is the most effective feedback modality during running?